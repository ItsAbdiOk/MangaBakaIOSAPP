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

    /// A count that could not be fetched is absent, never zero.
    ///
    /// "0 now" beside a saved search says it found nothing — a real and much
    /// worse statement than saying nothing at all, and the difference matters
    /// most on the failure it would otherwise be reporting as a result.
    @Test("An unanswered count is missing, not zero")
    func missingCountIsNotZero() async throws {
        let counts = LensCounts(repository: SilentRepository())
        let lens = try #require(SearchLens.presets.first)

        counts.load([lens])
        try await Task.sleep(for: .milliseconds(120))

        #expect(counts.counts[lens.id] == nil)
    }

    @Test("Each lens is counted once per session")
    func countsOncePerLens() async throws {
        let repository = CountingRepository()
        let counts = LensCounts(repository: repository)
        let lenses = Array(SearchLens.presets.prefix(2))

        counts.load(lenses)
        try await Task.sleep(for: .milliseconds(900))
        counts.load(lenses)
        try await Task.sleep(for: .milliseconds(300))

        #expect(repository.calls == 2, "the idle screen is returned to constantly")
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
        override func count(_ query: SearchQuery) async -> Int? { nil }
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

/// One save control, in the sheet that owns filters.
@Suite("Saving a lens has one home", .enabled(if: SourceTree.isAvailable))
struct LensSaveEntryTests {
    @Test("Search does not offer a second way to save")
    func onlyTheSheetSaves() throws {
        // Two entry points for one action is how they drift apart: the sheet
        // knows the filters, and a button on the results screen has to be told
        // about them separately.
        let search = try SourceTree.read("MangaBaka/Features/Search/SearchView.swift")
        #expect(!search.contains("Save as a lens"))
        let sheet = try SourceTree.read("MangaBaka/Features/Search/FilterSheet.swift")
        #expect(sheet.contains("SaveLensButton"))
    }

    @Test("The save control is inert until something is filtered")
    func inertUntilFiltered() throws {
        let sheet = try SourceTree.read("MangaBaka/Features/Search/FilterSheet.swift")
        #expect(sheet.contains("SaveLensButton(isEnabled: !query.isEmpty)"))
    }
}
