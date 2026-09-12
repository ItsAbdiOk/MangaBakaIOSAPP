import Foundation

/// The cast of a series, from AniList where possible and Shikimori where not.
///
/// AniList is the preferred source: better portraits, a real relevance sort,
/// and it is the tracker most of this app's other data is reconciled against.
/// From at least 2026-09-10 it returned HTTP 403 to every request with its own
/// message about being temporarily disabled; re-verified live on 2026-09-12
/// that it now answers normally. `aniListDownUntil` below still exists for
/// whichever future outage comes next.
///
/// **The fallback is silent by design.** A reader opening a series page has no
/// stake in which of two trackers answered; a banner saying one is down is a
/// report about our plumbing, not information about their manga. So a failure
/// on the preferred source is an internal detail, and the row either has a cast
/// or does not appear at all.
///
/// Silent here means invisible, not unrecorded: `lastOutcome` names which
/// source answered so a test can prove the fallback ran, and so the decision is
/// inspectable rather than folded away.
actor CharacterService {
    enum Source: String, Equatable, Sendable {
        case aniList
        case shikimori
        case none
    }

    private let aniList: AniListClient
    private let shikimori: ShikimoriClient

    /// Which source answered last. Diagnostic only — nothing on screen reads it.
    private(set) var lastOutcome: Source = .none

    /// How long a refusal from AniList is remembered before it is tried again.
    /// A session can outlive an outage — the app stays open across a day of
    /// reading — so the memory expires rather than lasting the session. Fifteen
    /// minutes is a guess: long enough that a series page opened twice does not
    /// pay the timeout twice, short enough that a fixed API is noticed soon.
    static let outageMemory: TimeInterval = 15 * 60

    /// Set only by a refusal from the service itself. A cancelled request, a
    /// dropped packet or being offline says nothing about AniList, and treating
    /// them as an outage used to drop the preferred source for the whole
    /// session over a reader leaving a page early.
    private var aniListDownUntil: Date?
    private let clock: any Clock

    private var aniListIsDown: Bool {
        guard let until = aniListDownUntil else { return false }
        return clock.now < until
    }

    init(
        aniList: AniListClient = AniListClient(),
        shikimori: ShikimoriClient = ShikimoriClient(),
        clock: any Clock = SystemClock()
    ) {
        self.aniList = aniList
        self.shikimori = shikimori
        self.clock = clock
    }

    /// The cast, or an empty list if neither source can answer.
    ///
    /// - Parameters:
    ///   - aniListID: from `source.anilist.id`. Nil skips straight to Shikimori.
    ///   - shikimoriID: from `source.shikimori.id`.
    func characters(aniListID: Int?, shikimoriID: Int?, limit: Int = 20) async -> [SeriesCharacter] {
        if let aniListID, !aniListIsDown {
            do {
                let cast = try await aniList.characters(mediaId: aniListID, limit: limit)
                lastOutcome = .aniList
                return cast
            } catch {
                // Only the service's own refusal counts as an outage. A rate
                // limit is about us; offline and transport failures are about
                // the network; a decode failure is a shape problem that will
                // recur and is cheap to hit again.
                if case .server = error {
                    aniListDownUntil = clock.now.addingTimeInterval(Self.outageMemory)
                }
            }
        }

        if let shikimoriID {
            if let cast = try? await shikimori.characters(mangaId: shikimoriID, limit: limit),
               !cast.isEmpty {
                lastOutcome = .shikimori
                return cast
            }
        }

        lastOutcome = .none
        return []
    }

    /// Lets a caller try AniList again before the memory expires.
    func clearOutageMemory() {
        aniListDownUntil = nil
    }

    /// Checks AniList once, at app launch, so the first series page opened
    /// does not pay AniList's own timeout before falling back to Shikimori.
    ///
    /// Abdi: "we can check if anilist is down at the start of the app and
    /// have shikimori take over if its not responding." Fire-and-forget from
    /// the caller's side — see `AppServices`/`RootView` wiring — so a slow or
    /// hanging AniList never delays the first screen drawing.
    ///
    /// Same rule as `characters(aniListID:shikimoriID:limit:)`: only a
    /// refusal AniList itself sent counts as an outage. A transport failure
    /// here says the network was unavailable at launch, not that AniList is
    /// down — priming the outage memory from that would hide a working
    /// AniList behind a phone that was still connecting to Wi-Fi.
    func primeAniListHealth() async {
        guard !aniListIsDown else { return }
        do {
            try await aniList.healthCheck()
        } catch {
            if case .server = error {
                aniListDownUntil = clock.now.addingTimeInterval(Self.outageMemory)
            }
        }
    }
}

/// Where a series' ids live in MangaBaka's own response, so the view layer does
/// not have to know the shape of the `source` block.
extension Series {
    var aniListID: Int? { trackerID("anilist") }
    var shikimoriID: Int? { trackerID("shikimori") }

    private func trackerID(_ key: String) -> Int? {
        guard let raw = source?[key]?.id else { return nil }
        return Int(raw)
    }
}
