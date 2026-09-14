import Foundation

/// The cast of a series, unioned from AniList and Shikimori.
///
/// AniList is the preferred source: better portraits, a real relevance sort,
/// and it is the tracker most of this app's other data is reconciled against.
/// From at least 2026-09-10 it returned HTTP 403 to every request with its own
/// message about being temporarily disabled; re-verified live on 2026-09-12
/// that it now answers normally. `aniListDownUntil` below still exists for
/// whichever future outage comes next.
///
/// **Union, not fallback.** Abdi, 2026-09-13, verbatim: "if a character is on
/// AniList but not on Shikimori, use AniList as the default. If it's on
/// Shikimori but AniList doesn't have that character, make sure you put it."
/// Before this both sources were asked one after the other and Shikimori was
/// only ever used when AniList had nothing at all — a character AniList
/// simply did not carry (a minor role, a spin-off cameo) never appeared even
/// though Shikimori had it. Both are asked concurrently now; AniList's cast
/// leads, in AniList's own order, and every Shikimori character that does not
/// fuzzy-match one already in that list (`CharacterNameMatch`) is appended
/// after it.
///
/// Silent about *which* source answered, same as before: a reader opening a
/// series page has no stake in that plumbing. `lastOutcome` is still recorded
/// for tests, now naming the union rather than a single winner (see
/// `Source.union`).
actor CharacterService {
    enum Source: String, Equatable, Sendable {
        case aniList
        case shikimori
        /// Characters were merged from both — the ordinary case once both
        /// sources answer with something.
        case union
        case none
    }

    /// One source's outcome for a single `characters()` call, so a caller can
    /// tell "asked and failed" from "asked and had nobody" from "never asked"
    /// (gap 17) — the same distinction `Fetched` draws generally, specialised
    /// here because a cast is a union of two independent asks rather than one.
    enum SourceOutcome: Equatable, Sendable {
        case notAsked
        case answered
        case failed(APIError)
    }

    /// The union, plus enough about each half to tell a real failure from a
    /// source that simply had nobody. `characters` alone is enough for any
    /// caller that only wants to render the row — `CharacterRow` needs no
    /// change to keep working against it.
    struct CharacterCast: Equatable, Sendable {
        let characters: [SeriesCharacter]
        let aniList: SourceOutcome
        let shikimori: SourceOutcome

        static let empty = CharacterCast(characters: [], aniList: .notAsked, shikimori: .notAsked)

        /// True only when every source that was asked failed outright — never
        /// true for "asked and got nothing", which needs no failure banner.
        /// The view (batch 2) reads this to choose `InlineFailure` over
        /// simply hiding the row.
        var failed: Bool {
            let asked = [aniList, shikimori].filter { $0 != .notAsked }
            guard !asked.isEmpty else { return false }
            return asked.allSatisfy {
                if case .failed = $0 { return true }
                return false
            }
        }
    }

    /// Internal, not private: `CharacterProfileView` used to build its own
    /// pair per presentation, which bypassed this service's outage memory —
    /// so a source that had just 403'd was asked again on every profile
    /// opened (review 2, item 63).
    let aniList: AniListClient
    let shikimori: ShikimoriClient

    /// Which source(s) contributed last. Diagnostic only — nothing on screen
    /// reads it.
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
    /// The refusal that set `aniListDownUntil`, so a caller that skips AniList
    /// because it is remembered as down still gets a real `APIError` in its
    /// `SourceOutcome.failed`, rather than `.notAsked` hiding an actual outage.
    private var aniListDownReason: APIError?
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

    private struct CacheKey: Hashable {
        let aniListID: Int?
        let shikimoriID: Int?
        let limit: Int
    }

    /// **A guess: 24 hours.** A series' cast is about as static as anything
    /// this app fetches — a new character appears when a new arc does — so
    /// the life is set by how long a stale cast is tolerable rather than by
    /// how often it changes.
    static let castCacheLife: TimeInterval = 24 * 60 * 60

    /// In memory only, and deliberately so: this is the one third-party answer
    /// on the series page that had no cache at all, so every reopen and every
    /// pager swipe cost AniList and Shikimori one request each. It is also the
    /// one place a third party could see the reader's browsing path in full,
    /// twice over — the cache is a privacy measure as much as a politeness
    /// one. Not on disk, because a cast is cheap to rebuild and a file is one
    /// more thing sign-out has to remember to clear.
    private var cache: [CacheKey: (cast: CharacterCast, storedAt: Date)] = [:]

    /// **A guess: 30.** AniList is asked for 20 and every unmatched Shikimori
    /// character used to be appended after them with no ceiling — Solo
    /// Leveling's Shikimori cast is 95, so one row could reach 40+ portrait
    /// fetches. Abdi asked for the union (2026-09-13) and confirmed the cap
    /// (2026-09-14, Q5): 20 from AniList plus a bounded tail keeps the "if
    /// it's on Shikimori but AniList doesn't have that character, make sure
    /// you put it" promise for the characters a reader will actually scroll
    /// to, without a whole second cast's worth of image requests behind it.
    static let mergedCastLimit = 30

    /// The union of both sources' casts.
    ///
    /// - Parameters:
    ///   - aniListID: from `source.anilist.id`. Nil skips AniList entirely.
    ///   - shikimoriID: from `source.shikimori.id`. Nil skips Shikimori.
    ///
    /// Both sources are asked concurrently — one being slow or throttled must
    /// not delay the other, since neither is a fallback for the other anymore.
    func characters(aniListID: Int?, shikimoriID: Int?, limit: Int = 20) async -> CharacterCast {
        let key = CacheKey(aniListID: aniListID, shikimoriID: shikimoriID, limit: limit)
        if let hit = cache[key], clock.now.timeIntervalSince(hit.storedAt) < Self.castCacheLife {
            return hit.cast
        }

        async let aniListAsk = fetchAniList(aniListID: aniListID, limit: limit)
        async let shikimoriAsk = fetchShikimori(shikimoriID: shikimoriID, limit: limit)
        let (aniListCast, aniListOutcome) = await aniListAsk
        let (shikimoriCast, shikimoriOutcome) = await shikimoriAsk

        var merged = aniListCast
        for character in shikimoriCast where !merged.contains(where: {
            CharacterNameMatch.matches($0.name, character.name)
        }) {
            guard merged.count < Self.mergedCastLimit else { break }
            merged.append(character)
        }

        lastOutcome = {
            switch (aniListCast.isEmpty, shikimoriCast.isEmpty) {
            case (false, false): .union
            case (false, true): .aniList
            case (true, false): .shikimori
            case (true, true): .none
            }
        }()

        let cast = CharacterCast(characters: merged, aniList: aniListOutcome, shikimori: shikimoriOutcome)
        // Never cache an answer where every source that was asked failed —
        // that would turn one 403 into a day of empty casts, which is the
        // outage memory's job and its job alone (15 minutes, not 24 hours).
        if !cast.failed { cache[key] = (cast, clock.now) }
        return cast
    }

    /// AniList's half of the union: skipped (`.notAsked`) with no id, remembered
    /// as down (`.failed`, the stored reason) without spending a request, or
    /// asked live.
    private func fetchAniList(
        aniListID: Int?, limit: Int
    ) async -> ([SeriesCharacter], SourceOutcome) {
        guard let aniListID else { return ([], .notAsked) }
        if aniListIsDown {
            return ([], .failed(aniListDownReason ?? .server(
                status: 403, message: "AniList is remembered as down.", party: .aniList
            )))
        }
        do {
            let cast = try await aniList.characters(mediaId: aniListID, limit: limit)
            return (cast, .answered)
        } catch {
            // Only the service's own refusal counts as an outage. A rate
            // limit is about us; offline and transport failures are about
            // the network; a decode failure is a shape problem that will
            // recur and is cheap to hit again. `.server` itself is not
            // enough either — see `isAniListOutage(status:)`.
            if case let .server(status, _, _) = error, Self.isAniListOutage(status: status) {
                aniListDownUntil = clock.now.addingTimeInterval(Self.outageMemory)
                aniListDownReason = error
            }
            return ([], .failed(error))
        }
    }

    /// Shikimori's half of the union: skipped with no id, otherwise asked
    /// live. Unlike the old fallback, an empty Shikimori answer is `.answered`
    /// — a real "no cast" is no longer discarded in favour of nothing.
    private func fetchShikimori(
        shikimoriID: Int?, limit: Int
    ) async -> ([SeriesCharacter], SourceOutcome) {
        guard let shikimoriID else { return ([], .notAsked) }
        do {
            let cast = try await shikimori.characters(mangaId: shikimoriID, limit: limit)
            return (cast, .answered)
        } catch {
            return ([], .failed(error))
        }
    }

    /// Lets a caller try AniList again before the memory expires. Drops the
    /// cast cache too: a caller asking for a retry wants live answers, and a
    /// cached union built while one source was down is exactly what they are
    /// trying to get past. Also the account-change hook — a cast is not
    /// personal, but nothing about the previous session should outlive it.
    func clearOutageMemory() {
        aniListDownUntil = nil
        aniListDownReason = nil
        cache.removeAll()
    }

    /// **`primeAniListHealth` was deleted 2026-09-14, on Abdi's call (Q4).**
    /// It POSTed to `graphql.anilist.co` on every cold launch, from every
    /// reader, including those who never open a series page — for an outage
    /// memory `fetchAniList` sets itself on the first real 403. Its stated
    /// purpose was keeping the first page from paying AniList's timeout
    /// "before falling back to Shikimori", and that stopped applying when the
    /// two sources became concurrent rather than sequential: nothing falls
    /// back anymore, and the check was holding one of AniList's 0.7 s spacing
    /// slots exactly when the first real cast request wanted it. `App
    /// Store submission (Q9: yes) is the other reason — an unprompted
    /// third-party request at launch is a line in the privacy manifest that
    /// buys nothing. `isAniListOutage` and the memory itself stay.

    /// Whether a `.server` failure is AniList's edge refusing us, versus
    /// AniList answering normally with nothing useful for this one series.
    ///
    /// `AniListClient` throws `.server` for two things: an actual non-2xx
    /// refusal (403, 5xx — and 404 for a stale/unknown media id, which is
    /// AniList correctly saying "no such series", not an outage), and a
    /// GraphQL `errors` body arriving inside a 200 (which carries that 200
    /// status through unchanged). A 200 with a simply-empty edges array is no
    /// longer one of them — gap 31 fixed `AniListClient.characters` to return
    /// `[]` for that case, a real answer rather than a thrown `.server(200)`.
    /// Before both fixes, every one of these set the same 15-minute outage
    /// timer, so one series with no AniList cast blacked out AniList for
    /// every other series page for 15 minutes (docs/reviews/third-parties.md
    /// finding 2, 2026-09-13). Only a refusal AniList's own edge sent — 403 or
    /// 5xx — is actually a reason to stop asking it.
    private static func isAniListOutage(status: Int) -> Bool {
        status == 403 || (500...599).contains(status)
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
