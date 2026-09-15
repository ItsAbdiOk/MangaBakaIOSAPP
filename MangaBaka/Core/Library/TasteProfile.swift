import Foundation
import os

/// The tags this reader actually likes, from their own library.
///
/// Exists to answer one question cheaply: given a series' tags, which of them
/// matter to *this* reader? A series carries up to a hundred and sixteen tags
/// (Solo Leveling does), the page shows twelve, and without this the twelve are
/// whichever the API happened to list first. A reader who reads fantasy and
/// action can have both buried behind "+104 more".
///
/// **What it costs.** One request, once per session, to an endpoint the app
/// already calls for the taste screen — and the answer is a few dozen rows. The
/// match itself is a set lookup per tag: about a hundred lookups against a set
/// of twenty, which is nothing on any device that can render the page it sits
/// on. It cannot slow the page down, because it never blocks it: tags render
/// unsorted if the profile has not arrived, and the profile arrives with the
/// same fetch that brings the tags.
actor TasteProfile {
    private let library: any LibraryProviding
    /// Where the fine-grained half of the answer comes from. Optional so tests
    /// and previews can run without a database.
    private let ledger: TasteLedger?
    /// The shared library walk. Without it this walked the library itself, and
    /// the library is 24.7 MB.
    private let snapshot: LibrarySnapshot?
    private var cached: Set<String>?
    private var cachedIDs: Set<Int>?
    private var inFlight: Task<Set<String>?, Never>?
    private var inFlightIDs: Task<Set<Int>, Never>?
    /// The raw `top-genres` answer, shared between `favouredTagNames()` and
    /// `favouredTagIDs()` so the endpoint is asked once per session instead of
    /// twice (R6/P6: launch and the first series page each asked it
    /// separately). Only a *successful* fetch is cached — same rule as
    /// `favouredTagNames`'s own `cached`, so a 429 or offline moment at launch
    /// does not lock the genre half of the profile to "nothing" for the rest
    /// of the session.
    private var cachedGenres: [TopGenre]?
    private var inFlightGenres: Task<[TopGenre]?, Never>?

    init(
        library: any LibraryProviding,
        ledger: TasteLedger? = nil,
        snapshot: LibrarySnapshot? = nil
    ) {
        self.library = library
        self.ledger = ledger
        self.snapshot = snapshot
    }

    /// Favoured tag names, lowercased for matching.
    ///
    /// Empty for a reader with no account or no library — which is correct, not
    /// a failure: with nothing to learn from, no tag is more theirs than
    /// another and the API's own order stands.
    func favouredTagNames() async -> Set<String> {
        if let cached { return cached }
        // Two series pages opened at once must not make two requests.
        if let inFlight { return await inFlight.value ?? [] }

        let task = Task<Set<String>?, Never> { [self] in
            let genres = await self.fetchTopGenres()
            return genres.map { Set($0.map { $0.tagName.lowercased() }) }
        }
        inFlight = task
        let result = await task.value
        // A failed request is not cached as "likes nothing" for the session;
        // the next series page asks again.
        if let result { cached = result }
        inFlight = nil
        return result ?? []
    }

    /// The shared `top-genres` fetch behind `favouredTagNames()` and
    /// `favouredTagIDs()`/`buildIDs()`. Dedups concurrent callers the same way
    /// the two public methods already dedup themselves, and — like them —
    /// only remembers a successful answer.
    private func fetchTopGenres() async -> [TopGenre]? {
        if let cachedGenres { return cachedGenres }
        if let inFlightGenres { return await inFlightGenres.value }

        let task = Task<[TopGenre]?, Never> { [library] in
            await library.topGenres()
        }
        inFlightGenres = task
        let genres = await task.value
        if let genres { cachedGenres = genres }
        inFlightGenres = nil
        return genres
    }

    /// The tags this reader's own reading is actually made of.
    ///
    /// Two sources, unioned:
    ///
    /// - **The ledger** — counted locally from the reader's library, so it can
    ///   name fine-grained tags like Regression or Murim. This is the half that
    ///   answers the question people actually ask.
    /// - **`top-genres`** — the API's own profile. Kept because it is computed
    ///   server-side from data we may not have paged through yet, and because
    ///   it costs one request that the taste screen makes anyway.
    ///
    /// Matched by id, never by name. The two endpoints spell tags differently
    /// and matching strings found exactly one tag in a series carrying 146.
    func favouredTagIDs() async -> Set<Int> {
        if let cachedIDs { return cachedIDs }
        // Two series pages opened at once must not both page the library.
        if let inFlightIDs { return await inFlightIDs.value }

        let task = Task<Set<Int>, Never> { [self] in
            await self.buildIDs()
        }
        inFlightIDs = task
        let ids = await task.value
        cachedIDs = ids
        inFlightIDs = nil
        return ids
    }

    /// Fills the ledger from the library, then reads both sources.
    ///
    /// The library pass is not an extra cost in the sense that matters: v1 list
    /// responses embed the whole `tags_v2` array, so the pages carry their own
    /// tags and nothing is fetched per series. The cap matches `LibraryModel`'s
    /// for the same reason: bounded, but far past any real library. Ten pages
    /// was not — Abdi's library is 937 entries against a 1,000 ceiling.
    private func buildIDs() async -> Set<Int> {
        if let ledger, let snapshot {
            // The whole `Result`, not its entries: `absorb` retracts every
            // source that is missing from what it is given, and a failed walk
            // and an empty library are the same `[]` (work-list 5).
            do {
                try await ledger.absorb(await snapshot.load())
            } catch {
                // R20/P20: a throw here used to be silent, and made the
                // whole profile read as "likes nothing" for the rest of the
                // session with no way to tell that apart from a reader with
                // a genuinely empty library.
                let description = String(describing: error)
                Self.logger.error("Ledger absorb failed: \(description, privacy: .public)")
            }
        }

        let local: Set<Int>
        do {
            local = try await ledger?.favouredIDs() ?? []
        } catch {
            let description = String(describing: error)
            Self.logger.error("Ledger favouredIDs failed: \(description, privacy: .public)")
            local = []
        }
        // Shared with `favouredTagNames()` (R6/P6): one `top-genres` request
        // per session instead of two, and a failure is not cached as "no
        // genres" — the next caller asks again.
        let genres = Set((await fetchTopGenres() ?? []).map(\.tagId))
        return local.union(genres)
    }

    /// The reader's tag affinities as a ranker, for ordering a list by how
    /// much each series shares with what they read. Empty — and so a no-op —
    /// for a reader with no library. Sixty tags rather than the highlight's
    /// thirty: a ranker wants the long tail, a highlight would drown in it.
    /// **A guess** — reasoned that a ranker wants more tags than a highlight,
    /// not measured against how a real ranking changes at 60 vs. some other
    /// number.
    func ranker() async -> TasteRanker {
        _ = await favouredTagIDs()   // fills the ledger from the library first
        let affinities: [TagAffinity]
        do {
            affinities = try await ledger?.favoured(limit: 60) ?? []
        } catch {
            // R20/P20: an empty ranker reads as "nothing in common with
            // anything", not as "the read failed" — worth knowing which.
            let description = String(describing: error)
            Self.logger.error("Ledger favoured(limit:) failed: \(description, privacy: .public)")
            affinities = []
        }
        return TasteRanker(affinities: affinities)
    }

    /// Counts a series the app has just decoded in full, if the reader has it.
    ///
    /// The library's own payload may carry no tags — see `TasteLedger.absorb`.
    /// This is the path that definitely works: every series page and every feed
    /// row carries `tags_v2`, so the profile fills in as the reader moves
    /// around rather than depending on one endpoint's shape.
    func note(_ series: Series) async {
        guard let ledger, let snapshot, !series.richTags.isEmpty else { return }
        // `.entries`, not `.wholeLibrary`: this only asks whether the reader
        // already has this one series, and a row that did arrive is a row that
        // is there whether or not the walk finished. A short walk costs a
        // series that is not counted this time, not a wrong count.
        let entries = await snapshot.load().entries
        guard let entry = entries.first(where: { $0.seriesId == series.id }) else { return }
        // Only drop the cache when something actually moved. `absorb`
        // returns false for a series already counted in this state, which is
        // what a reopen of a series page is — and dropping `cachedIDs` there
        // cost a full re-absorb of the library on the next
        // `favouredTagIDs()`, on the page's own critical path.
        let changed = (try? await ledger.absorb(series, as: entry.state)) ?? false
        if changed { cachedIDs = nil }
    }

    /// What the ledger actually knows, for a screen that has to say so.
    struct Diagnostics: Equatable, Sendable {
        /// Offered to the ledger at all, tagged or not.
        var seen = 0
        /// Counted into the affinities — seen, and tagged.
        var series = 0
        var tags = 0
    }

    func diagnostics() async -> Diagnostics {
        guard let ledger else { return Diagnostics() }
        return Diagnostics(
            seen: (try? await ledger.seenSeries()) ?? 0,
            series: (try? await ledger.countedSeries()) ?? 0,
            tags: (try? await ledger.knownTags()) ?? 0
        )
    }

    /// Forgets everything learned from the account that was signed in.
    ///
    /// For a token change, which is a change of person. The in-memory caches
    /// alone are not enough: the ledger is on disk and survives a relaunch, so
    /// without this a new reader inherits the last one's taste and every
    /// recommendation is quietly about somebody else's library.
    ///
    /// - Returns: false when the on-disk clear failed. This was a bare
    ///   `try? await ledger?.clear()` and nothing said so — the same gap-74
    ///   shape as `discardCachedFeeds`, on the one cache whose survival is
    ///   about the wrong person. `forgetPreviousAccount` shows its existing
    ///   failure toast on false. The in-memory caches are dropped either way:
    ///   a failed disk clear is no reason to keep serving the old profile
    ///   from RAM as well.
    @discardableResult
    func forgetEverything() async -> Bool {
        var cleared = true
        if let ledger {
            do {
                try await ledger.clear()
            } catch let error {
                let description = String(describing: error)
                Self.logger.error("Taste ledger clear failed: \(description, privacy: .public)")
                cleared = false
            }
        }
        invalidate()
        return cleared
    }

    /// Matches `SeriesRepository+Cache`'s own logger: a clear that silently
    /// failed is the thing gap 74 was about, and a log is the minimum.
    private static let logger = Logger(
        subsystem: "dev.abdirahmanmohamed.mangabaka", category: "taste"
    )

    /// Forgets the profile, so a change to the library is reflected.
    func invalidate() {
        cached = nil
        cachedIDs = nil
        cachedGenres = nil
        inFlight = nil
        inFlightIDs = nil
        inFlightGenres = nil
    }
}

enum TagOrdering {
    /// A series' tags with the reader's own interests first.
    ///
    /// A stable partition, not a sort: the API's ordering is meaningful within
    /// each group — it leads with the tags most characteristic of the series —
    /// and reshuffling it would trade one arbitrary order for another.
    static func favouredFirst(_ tags: [String], favoured: Set<String>) -> [String] {
        guard !favoured.isEmpty else { return tags }
        let mine = tags.filter { favoured.contains($0.lowercased()) }
        let rest = tags.filter { !favoured.contains($0.lowercased()) }
        return mine + rest
    }

    static func isFavoured(_ tag: String, favoured: Set<String>) -> Bool {
        favoured.contains(tag.lowercased())
    }
}
