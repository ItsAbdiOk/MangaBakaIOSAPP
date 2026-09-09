import Foundation

/// The cast of a series, from AniList where possible and Shikimori where not.
///
/// AniList is the preferred source: better portraits, a real relevance sort,
/// and it is the tracker most of this app's other data is reconciled against.
/// It is also, as of 2026-09-10, returning HTTP 403 to every request with its
/// own message about being temporarily disabled.
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

    /// Remembered for the session so a series page opened twice does not pay
    /// AniList's timeout twice over. Not persisted: an outage that ends should
    /// end for the reader on their next launch without them clearing anything.
    private var aniListIsDown = false

    init(aniList: AniListClient = AniListClient(), shikimori: ShikimoriClient = ShikimoriClient()) {
        self.aniList = aniList
        self.shikimori = shikimori
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
                // A rate limit is about us and passes; anything else is taken
                // as the service being unavailable for this session, because
                // retrying a disabled API on every series page costs the reader
                // a wait before every fallback.
                if case .rateLimited = error {} else { aniListIsDown = true }
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

    /// Lets a new launch — or a test — try AniList again.
    func clearOutageMemory() {
        aniListIsDown = false
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
