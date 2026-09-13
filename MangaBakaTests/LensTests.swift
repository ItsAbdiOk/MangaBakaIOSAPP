import Testing
import Foundation
@testable import MangaBaka

/// Saved searches and the screen they live on.
@Suite("Lenses")
@MainActor
struct LensTests {
    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "lens.tests.\(UUID().uuidString)"))
    }

    /// Polls instead of sleeping a fixed amount, so a test does not race the
    /// model's internal 250ms spacing between lens counts on a busy machine.
    /// Bounded, so a genuine bug still fails rather than hanging.
    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            await Task.yield()
        }
    }

    @Test("A repeated search moves up rather than being listed twice")
    func recentsDeduplicate() throws {
        let recents = RecentSearches(defaults: try defaults())
        recents.record("murim")
        recents.record("regression")
        recents.record("MURIM")

        #expect(recents.terms == ["MURIM", "regression"])
    }

    @Test("Recents stop at six")
    func recentsAreCapped() throws {
        let recents = RecentSearches(defaults: try defaults())
        for index in 1...9 { recents.record("term\(index)") }

        #expect(recents.terms.count == 6)
        #expect(recents.terms.first == "term9", "newest first")
        #expect(!recents.terms.contains("term1"))
    }

    @Test("A stray keystroke is not a search")
    func recentsIgnoreNoise() throws {
        let recents = RecentSearches(defaults: try defaults())
        recents.record("")
        recents.record("   ")
        recents.record("a")

        #expect(recents.terms.isEmpty)
    }

    @Test("Recents survive a relaunch")
    func recentsPersist() throws {
        let store = try defaults()
        RecentSearches(defaults: store).record("murim")

        #expect(RecentSearches(defaults: store).terms == ["murim"])
    }

    @Test("A term dismissed with its row's × is dropped, not just hidden")
    func removeDropsOneTerm() throws {
        let recents = RecentSearches(defaults: try defaults())
        recents.record("murim")
        recents.record("regression")

        recents.remove("murim")

        #expect(recents.terms == ["regression"])
    }

    /// Six are stored (`RecentSearches.limit`) but only the newest four ever
    /// draw on the idle screen — Abdi asked for "the last three or four
    /// searches" on 2026-09-13, so the screen shows fewer than the history
    /// actually keeps.
    @Test("Only the newest four recents are shown, even though six are kept")
    func visibleCapsAtFour() throws {
        let recents = RecentSearches(defaults: try defaults())
        for index in 1...6 { recents.record("term\(index)") }

        #expect(recents.terms.count == 6, "Sanity: all six are still stored")
        let visible = RecentSearches.visible(recents.terms)
        #expect(visible.count == 4)
        #expect(visible == ["term6", "term5", "term4", "term3"])
    }

    @Test("visible(_:limit:) never asks for more than there are")
    func visibleShortListIsUnchanged() {
        #expect(RecentSearches.visible(["only"], limit: 4) == ["only"])
        #expect(RecentSearches.visible([], limit: 4).isEmpty)
    }

    /// A lens as it would be built from a plain query, for tests that need
    /// one but do not care about its name or filters — presets used to fill
    /// this role; see `SearchLens`'s doc comment for why they are gone.
    private func lens(_ id: String, text: String = "x") -> SearchLens {
        SearchLens(id: id, name: id, rule: "q: \(text)", query: SearchQuery(text: text))
    }

    /// A count that could not be fetched is absent, never zero.
    ///
    /// "0 now" beside a saved search says it found nothing — a real and much
    /// worse statement than saying nothing at all, and the difference matters
    /// most on the failure it would otherwise be reporting as a result.
    @Test("An unanswered count is missing, not zero")
    func missingCountIsNotZero() async throws {
        let repository = SilentRepository()
        let counts = LensCounts(repository: repository)
        let lens = lens("a")

        counts.load([lens])
        // Gate on the repository having actually been asked, rather than
        // sleeping past the 250ms internal spacing.
        await waitUntil { repository.asked }

        #expect(counts.counts[lens.id] == nil)
    }

    @Test("Each lens is counted once per session")
    func countsOncePerLens() async throws {
        let repository = CountingRepository()
        let counts = LensCounts(repository: repository)
        let lenses = [lens("a"), lens("b")]

        counts.load(lenses)
        await waitUntil { repository.calls == lenses.count }
        counts.load(lenses)
        // Every lens is already asked, so this second load should start no
        // task at all (see LensCounts.load's `pending` guard). That is the
        // claim under test, so the test has to give a task room to run
        // before it looks: `load` counts inside a main-actor `Task {}`, and
        // this test is main-actor too, so without a suspension here a
        // regression that scheduled a duplicate walk would still read 2 —
        // the duplicate could not have started yet (search review, tests
        // finding 6). 600ms is more than twice the walk's own 250ms
        // spacing, so a second walk would have counted at least one lens.
        try? await Task.sleep(for: .milliseconds(600))
        #expect(repository.calls == 2, "the idle screen is returned to constantly")
    }

    /// 2026-09-13: the walk is the app's own idea, so it asks at
    /// `.background` — capped below the full 30/min search window and made
    /// to wait for room rather than compete with a typed search for it.
    /// Every other stub in this file overrides the plain `count(_:)`, which
    /// the protocol extension forwards to *without* the priority, so none
    /// of them could see this regress to `.userInitiated` (the state that
    /// put "Too many requests" on the series page — `RateLimitTests`'
    /// `RequestPriorityBudgetTests` doc comment).
    @Test("The idle-screen walk asks for every count at background priority")
    func walkCountsAtBackgroundPriority() async throws {
        let repository = PriorityRecordingRepository()
        let counts = LensCounts(repository: repository)
        let lenses = [lens("a"), lens("b")]

        counts.load(lenses)
        await waitUntil { repository.countPriorities.count == lenses.count }

        #expect(
            repository.countPriorities == [.background, .background],
            "a nil here means the ask bypassed the priority-aware overload entirely"
        )
    }

    /// The filter panel's live preview count goes through
    /// `LensCounts.count(_:)`, not the walk — and on HEAD that one still
    /// calls the priority-less `repository.count(query)`, which the real
    /// repository sends at `.userInitiated`. A reader flicking through
    /// rating segments therefore spends full-window search slots, and can
    /// lock their own typed search out (search review, summary #4).
    ///
    /// Expected to fail on HEAD with: `countPriorities == [.background]`
    /// → actual `[nil]`. Passes once Batch 1 Lane B lands
    /// `repository.count(query, priority: .background)` in
    /// `LensCounts.count(_:)` (`LensCounts.swift:143`).
    @Test("The panel's preview count also asks at background priority")
    func previewCountIsBackgroundPriority() async throws {
        let repository = PriorityRecordingRepository()
        let counts = LensCounts(repository: repository)

        _ = await counts.count(SearchQuery(text: "murim"))

        #expect(repository.countPriorities == [.background])
    }

    /// Leaving Search cancels the walk. The lenses it had not reached were
    /// already marked as asked, so they were never counted for the rest of
    /// the session — a cancellation treated as an answer.
    @Test("Lenses a cancelled walk never reached are counted next time")
    func cancelledWalkIsResumed() async throws {
        let repository = CountingRepository()
        let counts = LensCounts(repository: repository)
        let lenses = [lens("a"), lens("b"), lens("c")]

        counts.load(lenses)
        // Cancel as soon as one lens has been counted, instead of racing a
        // fixed sleep against the walk's own 250ms spacing — the exact race
        // that failed the pre-push hook's busier simulator 3/3.
        await waitUntil { repository.calls >= 1 }
        counts.cancel()
        let reached = repository.calls
        #expect(reached < lenses.count, "The walk must still have had lenses left")

        counts.load(lenses)
        await waitUntil { repository.calls == lenses.count }
        #expect(repository.calls == lenses.count, "Every lens counted exactly once across the two walks")
    }

    /// A count that did not come back — offline, rate limited — is not an
    /// answer either, and was likewise marked as asked for the session.
    @Test("An unanswered count is asked again next time")
    func unansweredCountIsRetried() async throws {
        let repository = FlakyRepository()
        let counts = LensCounts(repository: repository)
        let lens = lens("a")

        counts.load([lens])
        await waitUntil { repository.attempts == 1 }
        #expect(counts.counts[lens.id] == nil)

        // `load` is a no-op while the first walk is still in its spacing
        // sleep after the failed ask, so keep offering it until the walk has
        // ended and the second ask goes out — then wait on the model's
        // state, since the stub is entered before its answer is written.
        await waitUntil {
            counts.load([lens])
            return repository.attempts == 2
        }
        await waitUntil { counts.counts[lens.id] == 12 }
        #expect(counts.counts[lens.id] == 12, "The second ask must reach the network")
    }

    /// 2026-09-13: never retry into a 429. A nil answer here is almost always
    /// the search window refusing this walk (`LensCounts` now runs at
    /// `.background` priority, which shares the same 30/min window a
    /// reader's own search needs), so the rest of the queue must not be asked
    /// one at a time into the same refusal.
    ///
    /// Expected to fail before the fix: the old loop only skipped the failed
    /// lens and slept before asking the next one, so `repository.calls` would
    /// have reached `lenses.count` well within the wait below, not stopped
    /// at 1.
    @Test("A failed count stops the walk instead of asking the rest of the queue")
    func failedCountStopsTheWalk() async throws {
        let repository = FailsFirstThenSucceedsRepository()
        let counts = LensCounts(repository: repository)
        let lenses = [lens("a"), lens("b"), lens("c")]

        counts.load(lenses)
        await waitUntil { repository.calls >= 1 }
        // Long enough that the old sleep-and-continue behaviour would have
        // reached the second and third lens well within it.
        try? await Task.sleep(for: .milliseconds(400))
        #expect(repository.calls == 1, "The walk must stop at the first failure, not press on")
        #expect(counts.counts.isEmpty)

        // The next `load()` retries the failed lens and reaches the ones left
        // behind it, same as any other failed lens (see `queued`'s doc
        // comment) — a stop is not a drop.
        // Wait on the answers landing, not on the asks going out: `calls`
        // ticks when a count is asked, `counts` fills when it returns.
        await waitUntil {
            counts.load(lenses)
            return counts.counts.count == lenses.count
        }
        #expect(counts.counts.count == lenses.count, "A later walk must still reach every lens")
        #expect(repository.calls == 1 + lenses.count)
    }

    /// Fails the very first count ever asked for, across any lens; answers
    /// every one after that.
    private final class FailsFirstThenSucceedsRepository: StubRepositoryBase, @unchecked Sendable {
        private let lock = NSLock()
        private var asks = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return asks }

        override func count(_ query: SearchQuery) async -> Int? {
            let isFirstEver = lock.withLock {
                asks += 1
                return asks == 1
            }
            return isFirstEver ? nil : 12
        }
    }

    /// Fails the first ask, answers the rest.
    private final class FlakyRepository: StubRepositoryBase, @unchecked Sendable {
        private let lock = NSLock()
        private var asks = 0
        var attempts: Int {
            lock.lock(); defer { lock.unlock() }
            return asks
        }

        override func count(_ query: SearchQuery) async -> Int? {
            first() ? nil : 12
        }

        private func first() -> Bool {
            lock.lock(); defer { lock.unlock() }
            asks += 1
            return asks == 1
        }
    }

    @Test("A lens saved from a filter keeps the filter, not the page")
    func savingResetsThePage() throws {
        let store = SearchLensStore(defaults: try defaults())
        var query = SearchQuery(text: "murim")
        query.page = 4

        #expect(store.save(name: "Murim", query: query))
        #expect(store.own.first?.query.page == 1)
    }

    @Test("A lens that filters nothing is refused")
    func emptyLensIsRefused() throws {
        let store = SearchLensStore(defaults: try defaults())
        #expect(!store.save(name: "Everything", query: SearchQuery()))
        #expect(store.own.isEmpty)
    }

    /// Answers nothing, the way a rate-limited or offline app does.
    private final class SilentRepository: StubRepositoryBase, @unchecked Sendable {
        private let lock = NSLock()
        private var wasAsked = false
        var asked: Bool {
            lock.lock(); defer { lock.unlock() }
            return wasAsked
        }

        override func count(_ query: SearchQuery) async -> Int? {
            lock.withLock { wasAsked = true }
            return nil
        }
    }

    private final class CountingRepository: StubRepositoryBase, @unchecked Sendable {
        private let lock = NSLock()
        private var counted = 0
        var calls: Int {
            lock.lock(); defer { lock.unlock() }
            return counted
        }

        override func count(_ query: SearchQuery) async -> Int? {
            bump()
            return 12
        }

        /// Synchronous, because NSLock is unavailable from an async context.
        private func bump() {
            lock.lock(); defer { lock.unlock() }
            counted += 1
        }
    }
}

/// How a lens is named and described, and what saving one over another
/// says. Its own suite so `LensTests` stays under the lint's body ceiling.
@Suite("Lens names")
@MainActor
struct LensNamingTests {
    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "lens.names.\(UUID().uuidString)"))
    }

    /// `describe` used to skip the year fields, so a lens built from Year
    /// alone — which `save` accepts, since `isEmpty` counts a year — was
    /// named "Everything", the one thing `save`'s own comment says a lens
    /// must never claim (review 2026-09-13, UX#4).
    @Test("A year-only lens is named after the year, not \"Everything\"")
    func yearOnlyLensIsNamed() {
        var query = SearchQuery()
        query.yearFrom = 2020
        query.yearTo = 2020
        #expect(SearchLens.describe(query) == "year: 2020")

        query.yearTo = 2023
        #expect(SearchLens.describe(query) == "year: 2020\u{2013}2023")

        query.yearFrom = nil
        #expect(SearchLens.describe(query) == "year: to 2023")

        query.yearFrom = 2020
        query.yearTo = nil
        #expect(SearchLens.describe(query) == "year: from 2020")
    }

    /// Same hole for genres once they stopped riding in `tags`: a lens from
    /// the Genres sheet alone would have been "Everything" too.
    @Test("A genre-only lens is named after the genre")
    func genreOnlyLensIsNamed() {
        var query = SearchQuery()
        query.genres = ["slice_of_life"]
        #expect(SearchLens.describe(query) == "genre: slice of life")

        query.genres = ["action", "romance"]
        // AND, because that is what the API does: `genre=action` 31,025,
        // `genre=romance` 100,947, both together 6,692 (`/v1/series/search`,
        // 2026-09-13).
        #expect(SearchLens.describe(query) == "genres: action AND romance")
    }

    /// The control: a text-only lens keeps the name it always had.
    @Test("A text-only lens is still named after the text")
    func textOnlyLensIsNamed() {
        #expect(SearchLens.describe(SearchQuery(text: "murim")) == "\u{201C}murim\u{201D}")
    }

    /// Two tags used to be joined "A, B" unless `tagMode` was literally
    /// "and" — which read as "either" for a request that is always AND
    /// (`SearchQuery.tagMode`'s doc has the 164-either-way measurement).
    @Test("Two tags read as AND whatever tagMode says")
    func tagsReadAsAnd() {
        var query = SearchQuery()
        query.tags = ["Isekai", "Regression"]
        #expect(SearchLens.describe(query) == "tags: Isekai AND Regression")
        query.tagMode = "or"
        #expect(SearchLens.describe(query) == "tags: Isekai AND Regression")
    }

    // MARK: - Overwrite

    /// Saving under a name already taken replaces the old lens, and used
    /// to do so without a word (review 2026-09-13, UX#12). The store now
    /// says whose place the new lens took, so the caller's toast can.
    @Test("Saving over an existing name reports which lens was replaced")
    func overwriteIsReported() throws {
        let store = SearchLensStore(defaults: try defaults())
        #expect(store.save(name: "Seinen", query: SearchQuery(text: "seinen")))
        #expect(store.replaced == nil, "a first save replaces nothing")

        #expect(store.save(name: "seinen", query: SearchQuery(text: "seinen, completed")))
        #expect(store.replaced == "Seinen", "the name as it was saved, not as it was retyped")
        #expect(store.own.count == 1)

        #expect(store.save(name: "Josei", query: SearchQuery(text: "josei")))
        #expect(store.replaced == nil, "the report is per save, not sticky")
    }
}

/// One save control, in the panel that owns filters.
///
/// Lived in `FilterSheet.swift` until 2026-09-13, when the controls moved
/// into `FilterPanel` so the same panel could sit inline on the idle screen
/// as well as inside the sheet — see `FilterPanel`'s doc comment.
@Suite("Saving a lens has one home", .enabled(if: SourceTree.isAvailable))
struct LensSaveEntryTests {
    @Test("Search does not offer a second way to save")
    func onlyTheSheetSaves() throws {
        // Two entry points for one action is how they drift apart: the panel
        // knows the filters, and a button on the results screen has to be told
        // about them separately.
        let search = try SourceTree.read("MangaBaka/Features/Search/SearchView.swift")
        #expect(!search.contains("Save as a lens"))
        let panel = try SourceTree.read("MangaBaka/Features/Search/FilterPanel.swift")
        #expect(panel.contains("SaveLensButton"))
    }

    // `inertUntilFiltered` used to live here, pinning the literal call
    // `SaveLensButton(isEnabled: !query.isEmpty)`. Removed 2026-09-13: a
    // whitespace change broke it and a renamed-but-equivalent call passed
    // it. `FilterPanel.canShow(query:)` in `SearchScreenTests` is the
    // behavioural version of the same rule.
}

/// The three preset lenses are gone — see `SearchLens`'s doc comment for
/// where they came from and why Abdi asked (2026-09-13) to scrap them.
@Suite("Presets are gone", .enabled(if: SourceTree.isAvailable))
struct SearchLensPresetsGoneTests {
    @Test("SearchLens no longer defines any presets")
    func noPresetsProperty() throws {
        let source = try SourceTree.read("MangaBaka/Features/Search/SearchLens.swift")
        #expect(!source.contains("static let presets"))
    }

    @Test("Nothing in the app still reaches for SearchLens.presets")
    func noPresetReferences() throws {
        for path in [
            "MangaBaka/Features/Search/SearchIdleView.swift",
            "MangaBaka/Features/Search/SearchView.swift",
            "MangaBaka/Features/Search/FilterSheet.swift",
            "MangaBaka/Features/Search/FilterPanel.swift"
        ] {
            let source = try SourceTree.read(path)
            #expect(!source.contains("SearchLens.presets"), "\(path) still references the removed presets")
            #expect(!source.contains("\"Presets\""), "\(path) still labels a Presets section")
        }
    }
}

/// One `FilterPanel`, worn by two hosts — the sheet reached from mid-search
/// "Filters", and the idle screen's own inline copy. Abdi: "I like the
/// Filter sheet... keep that on the main search page" — this is what makes
/// that one panel rather than two designs of the same controls.
@Suite("The filter panel has one definition and two hosts", .enabled(if: SourceTree.isAvailable))
struct FilterPanelWiringTests {
    @Test("FilterSheet wraps FilterPanel rather than duplicating its controls")
    func sheetUsesThePanel() throws {
        let sheet = try SourceTree.read("MangaBaka/Features/Search/FilterSheet.swift")
        #expect(sheet.contains("FilterPanel("))
        #expect(!sheet.contains("RatingSegments("), "the sheet must not re-implement the panel's controls")
    }

    @Test("The idle screen wires the same FilterPanel inline")
    func idleScreenUsesThePanel() throws {
        let idle = try SourceTree.read("MangaBaka/Features/Search/SearchIdleView.swift")
        #expect(idle.contains("FilterPanel("))
    }

    /// The Genres sheet used to write into `query.tags`, so a genre went to
    /// the wire as `tag=` and found 6-14% of the genre (measured figures on
    /// `SearchQuery.genres`). A grep, because a `Binding<[String]>` to the
    /// wrong array type-checks just as well as one to the right array.
    @Test("The Genres sheet writes query.genres, not query.tags")
    func genreSheetBindsGenres() throws {
        let panel = try SourceTree.read("MangaBaka/Features/Search/FilterPanel.swift")
        #expect(panel.contains("selected: $query.genres"))
        #expect(!panel.contains("genres: $genres, selected: $query.tags)"))
    }
}

/// The bar beside each tag in the picker.
///
/// It is not the design board's weight bar and cannot be: weight says how
/// central a tag is to *one series*, and a filter picker has no series. What a
/// bare tag does have is how many series carry it, which answers the question a
/// filter picker actually raises — is this narrow or broad.
@Suite("Tag breadth reads as four steps")
struct TagBreadthTests {
    private func tag(_ id: Int, count: Int?) -> MangaBaka.Tag {
        MangaBaka.Tag(
            id: id, name: "T\(id)", namePath: nil, parentId: nil, level: 0,
            description: nil, seriesCount: count, isGenre: nil, isSpoiler: nil,
            mergedWith: nil, contentRating: nil
        )
    }

    /// The first version scaled against the largest count and put every bar on
    /// step one, because tag counts are wildly skewed: a few genres carry tens
    /// of thousands and the tail carries dozens. Seen on device as eight
    /// identical bars in a row.
    @Test("A skewed catalogue still fills all four steps")
    func skewDoesNotFlattenTheBar() {
        // One giant and a long tail — the real shape of a tag catalogue.
        let counts = [40_000] + (0..<20).map { $0 + 5 }
        let tags = counts.enumerated().map { tag($0.offset, count: $0.element) }

        let steps = Set(tags.map { TagBreadth.step(for: $0, among: tags) })
        #expect(steps.count == 4, "a bar with one value in it is decoration")
        #expect(steps.allSatisfy { (1...4).contains($0) })
    }

    @Test("The broadest tag is at the top step and the narrowest at the bottom")
    func endsOfTheRange() {
        let tags = [tag(1, count: 5), tag(2, count: 500), tag(3, count: 50_000)]
        #expect(TagBreadth.step(for: tags[2], among: tags) == 4)
        #expect(TagBreadth.step(for: tags[0], among: tags) == 1)
    }

    @Test("A tag the API did not count reads as the narrowest rather than crashing")
    func missingCountIsLowest() {
        let tags: [MangaBaka.Tag] = [tag(1, count: nil), tag(2, count: 500)]
        #expect(TagBreadth.step(for: tags[0], among: tags) == 1)
    }
}

/// Mix can save a lens, and can filter by tag before it has ever blended.
@Suite("Mix filters", .enabled(if: SourceTree.isAvailable))
struct MixFilterTests {
    private func source() throws -> String {
        try SourceTree.read("MangaBaka/Features/Mix/MixFilterStrip.swift")
    }

    /// "One control, in the sheet that owns filters, so Search and Mix both get
    /// it" was the reasoning. Mix has a strip rather than a sheet, so for a
    /// while it was true of Search alone.
    @Test("Mix has the same save control Search does")
    func mixCanSaveALens() throws {
        #expect(try source().contains("SaveLensButton"))
        #expect(try source().contains("model.filters.isEmpty"), "inert until something is set")
    }

    // `tagsBeforeBlending` used to live here, asserting the absence of a
    // 40-character `if !model.dna.isEmpty {\n            VStack` snippet.
    // Removed 2026-09-13: it pinned indentation, not behaviour — reformatting
    // the strip broke it and moving the gate one line down passed it. The
    // rule it guarded ("a reader who wants these three, but it must have
    // Regression, must not have to blend once and discard the answer")
    // needs a view-state test against `MixModel`, which this file does not
    // have; recorded here so it is not re-proposed as a source grep.

    /// A tag picked before the first blend used to vanish the moment a blend
    /// returned a DNA that did not mention it — while still filtering results.
    @Test("A picked tag survives a blend that does not mention it")
    func pickedTagsSurvive() throws {
        #expect(try source().contains("pickedBeyondDNA"))
    }
}
