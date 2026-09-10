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

    /// A reader who wants "these three, but it must have Regression" used to
    /// have to blend once, discard the answer, and blend again.
    @Test("Tags can be required before the first blend")
    func tagsBeforeBlending() throws {
        let source = try source()
        #expect(
            !source.contains("if !model.dna.isEmpty {\n            VStack"),
            "the tag section must not be gated on a blend having already run"
        )
        #expect(source.contains("TagPickerSheet") || source.contains("isPickingTags"))
    }

    /// A tag picked before the first blend used to vanish the moment a blend
    /// returned a DNA that did not mention it — while still filtering results.
    @Test("A picked tag survives a blend that does not mention it")
    func pickedTagsSurvive() throws {
        #expect(try source().contains("pickedBeyondDNA"))
    }
}
