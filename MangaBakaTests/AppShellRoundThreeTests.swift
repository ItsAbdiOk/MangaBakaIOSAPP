import Foundation
import Testing
@testable import MangaBaka

/// The composition root's own joins, and the Settings screen's library walk.
///
/// Both are places where a correct rule was applied n−1 times out of n, or
/// where a whole screen's cost was paid for something nobody tapped. Neither
/// had a test: `AppServices.init` was a wall of assignments no test could
/// reach into, and `LibraryTransferSection` walked the library from `.task`.
@Suite("App shell wiring")
struct AppShellWiringTests {
    /// Records what the preference stores ask the repository to do.
    ///
    /// Everything else answers empty: this double exists for four lines of
    /// `AppServices`, not to stand in for a repository.
    private actor RecordingRepository: SeriesRepositoryProtocol {
        private(set) var ratings: [String]?
        private(set) var formats: [String]?
        private(set) var blocked: [Int]?

        func feed(_ feed: FeedKind, forceRefresh: Bool) async -> FeedResult {
            FeedResult(series: [], origin: .network)
        }
        func search(_ query: SearchQuery) async -> FeedResult {
            FeedResult(series: [], origin: .network)
        }
        func feedPage(_ feed: FeedKind, page: Int) async -> FeedResult {
            FeedResult(series: [], origin: .network)
        }
        func mix(seeds: [Int], filters: SearchQuery, excludedTags: [Int]) async -> MixResult { .empty }
        func extras(for seriesId: Int) async -> SeriesExtras { SeriesExtras() }
        func images(for seriesId: Int) async -> [SeriesImage]? { [] }
        func relationships(for seriesId: Int) async -> [SeriesRelationship]? { nil }
        func cachedSeriesCount() async -> Int { 0 }
        func count(_ query: SearchQuery) async -> Int? { nil }
        func updateLibraryExclusion(userID: String?) async {}

        func updateContentRatings(_ ratings: [String]) async { self.ratings = ratings }
        func updateFormats(_ formats: [String]) async { self.formats = formats }
        func updateBlockedTags(_ ids: [Int]) async { blocked = ids }
    }

    /// The library half of `wire`, which until item 59 nothing recorded.
    ///
    /// The old helper here built a *real* `LibraryService` — the only thing
    /// `wire`'s concrete parameter would accept — and a real one remembers
    /// nothing a test can read. So the kill criterion below was false for two
    /// of the five lines: `updateContentRatings` and `updateFormats` on the
    /// library could both be deleted and this suite stayed green, and those
    /// are the two that keep the reader's own recommendations inside their
    /// content-rating choice.
    private actor RecordingLibrary: LibraryFiltering {
        private(set) var ratings: [String]?
        private(set) var formats: [String]?

        func updateContentRatings(_ ratings: [String]) { self.ratings = ratings }
        func updateFormats(_ formats: [String]) { self.formats = formats }
    }

    private func defaults(_ name: String) throws -> UserDefaults {
        let suite = try #require(UserDefaults(suiteName: "wiring-\(name)-\(UUID().uuidString)"))
        return suite
    }

    /// Work-list 137. The three `onChange` assignments were n copies of one
    /// rule with no test on any of them, in a project whose own
    /// `XcconfigAssertions` names "a correct rule applied n−1 times out of n"
    /// as its characteristic defect.
    ///
    /// Kill criterion: delete any one of the **five** lines in
    /// `AppServices.wire` and exactly one of these five expectations fails.
    /// It says five now because it said three and meant three, while `wire`
    /// had five (item 59).
    ///
    /// Expected to fail before item 59 with a compile error, not a wrong
    /// value: `LibraryFiltering` did not exist and `wire` took a concrete
    /// `LibraryService`, so there was no way to write the two library
    /// expectations at all. The behavioural proof is the kill criterion
    /// itself — delete `await library.updateContentRatings(ratings)` from
    /// `wire` and `libraryRatings` below fails with `nil`, where before item
    /// 59 the whole suite stayed green.
    @Test("Every preference store reaches the repository and the library")
    @MainActor
    func everyStoreIsWired() async throws {
        let repository = RecordingRepository()
        let library = RecordingLibrary()
        let content = ContentPreferencesStore(defaults: try defaults("content"))
        let formats = FormatPreferencesStore(defaults: try defaults("formats"))
        let blocked = BlockedTagsStore(defaults: try defaults("blocked"))

        AppServices.wire(
            content: content, formats: formats, blocked: blocked, to: repository, library: library
        )

        await content.set(.erotica, allowed: true)
        await formats.set(.novel, allowed: false)
        await blocked.toggle(id: 42, name: "Gore")

        #expect(await repository.ratings == content.preferences.queryValues)
        #expect(await repository.formats == formats.preferences.queryValues)
        #expect(await repository.blocked == [42])
        // The two that had no assertion. Not a copy of the repository's
        // values by construction: `wire` passes each store's `queryValues` to
        // both, so if either line is deleted this one goes nil.
        #expect(await library.ratings == content.preferences.queryValues)
        #expect(await library.formats == formats.preferences.queryValues)
    }
}

/// Work-list 20, 17 and 105 — the Settings screen's export path.
@Suite("Library transfer, round three")
@MainActor
struct LibraryTransferRoundThreeTests {
    private final class SilentLibrary: LibraryProviding, @unchecked Sendable {
        func recommendationStatus() async throws(APIError) -> RecommendationStatus {
            throw APIError.offline
        }
        func recommendations(limit: Int, page: Int, excluding: [Int]) async -> PersonalRecommendations {
            PersonalRecommendations()
        }
        func library(page: Int, limit: Int) async -> [LibraryEntry] { [] }
        func hiddenTagIDs() async -> Set<Int>? { [] }
        func topGenres() async -> [TopGenre]? { [] }
        func add(seriesId: Int, state: LibraryEntry.State) async throws(APIError) -> Bool { true }
        func remove(seriesId: Int) async throws(APIError) {}
        func update(seriesId: Int, change: LibraryChange) async throws(APIError) {}
    }

    private func entry(_ seriesId: Int, chapter: Double? = nil) -> LibraryEntry {
        LibraryEntry(
            id: seriesId, seriesId: seriesId, state: .reading, progressChapter: chapter,
            progressVolume: nil, rating: nil, note: nil, startDate: nil, finishDate: nil,
            numberOfRereads: nil, priority: nil, isPrivate: nil, readLink: nil, series: nil
        )
    }

    /// Work-list 20. Every push of Settings used to walk the whole library on
    /// appearance — ~13 requests and ~25 MB for an export nobody had tapped.
    ///
    /// Expected to fail before the fix with: `loads == 1`, because
    /// `LibraryTransferSection.body` carried
    /// `.task { await model.loadEntriesIfNeeded() }`. The model is the seam
    /// the view's `.task` called, so a load that has not been asked for is
    /// visible here as a count of zero.
    @Test("Nothing is loaded until an export is actually asked for")
    func exportLoadsOnDemand() async {
        let loads = Counter()
        let model = LibraryTransferModel(library: SilentLibrary()) {
            await loads.bump()
            return [self.entry(1), self.entry(2)]
        }

        #expect(await loads.calls == 0)
        #expect(model.jsonFile == nil)
        #expect(!model.isExportReady)

        await model.loadEntriesIfNeeded()
        #expect(await loads.calls == 1)
        #expect(model.isExportReady)
    }

    /// Work-list 105. `jsonExportItem()` and `csvExportItem()` were called
    /// from inside `body`, so both re-encoded all 939 entries on every render.
    ///
    /// Expected to fail before the fix with: a compile error — there were no
    /// stored `jsonFile`/`csvFile`, only the two functions `body` called.
    /// Behaviourally: a second `loadEntriesIfNeeded` must not re-encode, and
    /// the payload must survive without the view asking for it again.
    @Test("The two export payloads are encoded once, not per render")
    func exportsAreEncodedOnce() async {
        let model = LibraryTransferModel(library: SilentLibrary()) { [entry(1), entry(2)] }
        await model.loadEntriesIfNeeded()
        let json = model.jsonFile?.data
        let csv = model.csvFile?.data
        await model.loadEntriesIfNeeded()

        #expect(json != nil)
        #expect(csv != nil)
        #expect(model.jsonFile?.data == json)
        #expect(model.csvFile?.data == csv)
    }

    /// Work-list 17. The walk appends pages with no dedupe, so a series that
    /// moves between pages while it is running arrives twice.
    ///
    /// Expected to fail before the fix with: a fatal error, not a failed
    /// expectation — `Dictionary(uniqueKeysWithValues:)` traps on a duplicate
    /// key, so the reader's own library crashed the Settings screen.
    @Test("A repeated series id in the library does not trap the preview count")
    func duplicateEntriesDoNotTrap() {
        let existing = [entry(1, chapter: 10), entry(1, chapter: 3), entry(2)]
        let parsed = [
            ImportedEntry(seriesId: 1, state: .reading, progressChapter: 12),
            ImportedEntry(seriesId: 3, state: .reading)
        ]
        let counts = LibraryTransferModel.count(parsed, against: existing)

        #expect(counts.updates == 1)
        #expect(counts.new == 1)
        // First wins, matching the walk's own rule: chapter 10, not 3, so an
        // import at 12 is an update rather than a skip.
        #expect(counts.skipped == 0)
    }

    private actor Counter {
        private(set) var calls = 0
        func bump() { calls += 1 }
    }
}
