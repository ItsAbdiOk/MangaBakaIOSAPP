import Foundation
import Testing
@testable import MangaBaka

/// The "Next volume" widget's snapshot plumbing: which candidate wins per
/// series, the sort/window/cap rule, and the cross-target JSON contract
/// `WidgetSnapshotTests` already holds `dueThisWeek`/`pickBackUp` to.
///
/// Split from `WidgetSnapshotTests` per the task brief, rather than folded in:
/// that suite's fixtures are built around the two lists that already exist,
/// and `nextVolumes` needed its own `SeriesWork`-shaped fixtures throughout.
@Suite("Next volume snapshot")
struct NextVolumeSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_789_000_000) // a Wednesday, 2026-09-09

    // MARK: - nextVolumeItems (selection/sort/cap)

    private func candidate(_ id: Int, _ title: String, daysOut: Int) -> WidgetSnapshot.NextVolumeEntry {
        WidgetSnapshot.NextVolumeEntry(
            seriesID: id, title: title, volumeLabel: "Vol. 1",
            date: now.addingTimeInterval(Double(daysOut) * 86_400),
            coverURL: nil, sourceName: "MangaBaka", sourceURL: nil
        )
    }

    @Test("Soonest first, within the 60-day window; further out does not appear")
    func windowAndSort() {
        let items = WidgetSnapshot.nextVolumeItems(
            candidates: [
                candidate(1, "Far", daysOut: 70), candidate(2, "Soon", daysOut: 3),
                candidate(3, "Later", daysOut: 20)
            ],
            now: now
        )
        #expect(items.map(\.title) == ["Soon", "Later"])
    }

    @Test("A date already in the past does not appear")
    func pastDateExcluded() {
        let items = WidgetSnapshot.nextVolumeItems(
            candidates: [candidate(1, "Already out", daysOut: -1)], now: now
        )
        #expect(items.isEmpty)
    }

    @Test("Capped at six even when more qualify")
    func cappedAtSix() {
        let candidates = (1...9).map { candidate($0, "S\($0)", daysOut: $0) }
        let items = WidgetSnapshot.nextVolumeItems(candidates: candidates, now: now)
        #expect(items.count == WidgetSnapshot.nextVolumeCap)
        #expect(items.map(\.seriesID) == [1, 2, 3, 4, 5, 6])
    }

    @Test("A series with two candidates keeps only its earliest")
    func dedupesBySeries() {
        let series1Later = WidgetSnapshot.NextVolumeEntry(
            seriesID: 1, title: "Two Editions", volumeLabel: "Vol. 2",
            date: now.addingTimeInterval(10 * 86_400), coverURL: nil,
            sourceName: "MangaBaka", sourceURL: nil
        )
        let items = WidgetSnapshot.nextVolumeItems(
            candidates: [series1Later, candidate(1, "Two Editions", daysOut: 2)], now: now
        )
        #expect(items.count == 1)
        #expect(items.first?.volumeLabel == "Vol. 1")
    }

    @Test("No candidates produce nothing, not a crash")
    func emptyIsEmpty() {
        #expect(WidgetSnapshot.nextVolumeItems(candidates: [], now: now).isEmpty)
    }

    // MARK: - nextVolumeCandidates (the cache-only gathering step)

    private func work(releaseDate: String?) -> SeriesWork {
        SeriesWork(
            id: "1", sequenceString: "1", sequenceNumeric: 1, subTitle: nil,
            releaseDate: releaseDate, pages: nil, prices: nil, identifiers: nil,
            links: nil, images: nil
        )
    }

    private func libraryEntry(
        _ seriesId: Int, title: String, state: LibraryEntry.State = .reading
    ) -> LibraryEntry {
        LibraryEntry(
            id: seriesId, seriesId: seriesId, state: state, progressChapter: nil,
            progressVolume: nil, rating: nil, note: nil, startDate: nil, finishDate: nil,
            numberOfRereads: nil, priority: nil, isPrivate: nil, readLink: nil,
            series: SeriesFactory.make(id: seriesId, title: title)
        )
    }

    /// A repository whose `cachedExtras` answers from a fixed table and
    /// nothing else — the same shape `DueThisWeekTests.StubExtrasRepository`
    /// uses to prove `feedDueWorks` never fetches, written fresh here because
    /// that type is private to its own file.
    private final class StubCacheRepository: SeriesRepositoryProtocol, @unchecked Sendable {
        var extrasByID: [Int: SeriesExtras] = [:]
        func cachedExtras(for seriesId: Int) async -> SeriesExtras? { extrasByID[seriesId] }
        func feed(_ feed: FeedKind, forceRefresh: Bool) async -> FeedResult {
            FeedResult(series: [], origin: .network)
        }
        func search(_ query: SearchQuery) async -> FeedResult { FeedResult(series: [], origin: .network) }
        func feedPage(_ feed: FeedKind, page: Int) async -> FeedResult {
            FeedResult(series: [], origin: .network)
        }
        func mix(seeds: [Int], filters: SearchQuery, excludedTags: [Int]) async -> MixResult { .empty }
        func extras(for seriesId: Int) async -> SeriesExtras { extrasByID[seriesId] ?? SeriesExtras() }
        func images(for seriesId: Int) async -> [SeriesImage]? { [] }
        func relationships(for seriesId: Int) async -> [SeriesRelationship]? { nil }
        func updateContentRatings(_ ratings: [String]) async {}
        func updateFormats(_ formats: [String]) async {}
        func updateLibraryExclusion(userID: String?) async {}
        func updateBlockedTags(_ ids: [Int]) async {}
        func cachedSeriesCount() async -> Int { 0 }
        func count(_ query: SearchQuery) async -> Int? { nil }
    }

    /// A dropped series with a dated volume is left out; a paused one is
    /// kept. Fails before `wantsNextVolume` with `candidates.count == 2`.
    @Test("Dropped and completed series never reach the widget; paused ones do")
    func filtersByLibraryState() async {
        let repo = StubCacheRepository()
        for id in [1, 2, 3, 4] {
            repo.extrasByID[id] = SeriesExtras(volumes: [
                SeriesWork.Volume(number: "3", editions: [work(releaseDate: "2026-10-03")])
            ])
        }
        let candidates = await WidgetSnapshot.nextVolumeCandidates(
            from: [
                libraryEntry(1, title: "Dropped", state: .dropped),
                libraryEntry(2, title: "Done", state: .completed),
                libraryEntry(3, title: "Paused", state: .paused),
                libraryEntry(4, title: "Someday", state: .planToRead)
            ],
            repository: repo, now: now
        )
        #expect(candidates.map(\.seriesID) == [3])
    }

    /// Expected to fail before `nextVolumeCandidates` existed with a compile
    /// error (no such method) — this is the gathering step the widget's
    /// snapshot write needs and had no path to before this change.
    @Test("A library series with cached works carrying a forthcoming date is picked up")
    func picksUpCachedWork() async {
        let repo = StubCacheRepository()
        repo.extrasByID[42] = SeriesExtras(volumes: [
            SeriesWork.Volume(number: "12", editions: [work(releaseDate: "2026-10-03")])
        ])
        let candidates = await WidgetSnapshot.nextVolumeCandidates(
            from: [libraryEntry(42, title: "Delicious in Dungeon")], repository: repo, now: now
        )
        #expect(candidates.count == 1)
        #expect(candidates.first?.seriesID == 42)
        #expect(candidates.first?.volumeLabel == "Vol. 12")
        #expect(candidates.first?.sourceName == "MangaBaka")
        // A `works` row is MangaBaka's own and owes nobody a per-row link.
        #expect(candidates.first?.sourceURL == nil)
    }

    // MARK: - The second source: the persisted editions answer

    private func annAnswer(_ number: Int, _ date: String) -> VolumeEditionAnswer {
        let edition = VolumeEdition(
            catalogue: .animeNewsNetwork, language: "en", languageRole: .english,
            editionTitle: "Solo Leveling"
        )
        let volume = EditionVolume(
            number: number, title: "Solo Leveling (GN \(number))", releaseDate: PartialDate.parse(date),
            isbn13: nil, format: .print, edition: edition,
            sourceLink: URL(string: "https://www.animenewsnetwork.com/encyclopedia/releases.php?id=1")
        )
        return VolumeEditionAnswer(
            shelves: [EditionShelf(edition: edition, volumes: [volume])],
            credits: [.animeNewsNetwork], failures: [:], unaskedReason: nil
        )
    }

    private func store(_ answers: [Int: VolumeEditionAnswer]) async throws -> EditionAnswerStore {
        let store = EditionAnswerStore(database: try AppDatabase.inMemory(), clock: TestClock(now: now))
        for (id, answer) in answers { await store.write(answer, for: id) }
        return store
    }

    /// The Solo Leveling case from the brief: the page was opened last week,
    /// the six-hour `works` cache has expired, ANN's answer is on disk.
    /// Fails before the store was wired in with `candidates.isEmpty` (and,
    /// literally, with a compile error — `editionAnswers:` did not exist).
    @Test("A persisted ANN answer fills a series the works cache knows nothing about")
    func editionsFillWhereWorksKnowsNothing() async throws {
        let editions = try await store([42: annAnswer(12, "2026-10-03")])
        let candidates = await WidgetSnapshot.nextVolumeCandidates(
            from: [libraryEntry(42, title: "Solo Leveling")], repository: StubCacheRepository(),
            editionAnswers: editions, now: now
        )
        #expect(candidates.count == 1)
        #expect(candidates.first?.volumeLabel == "Vol. 12")
        #expect(candidates.first?.sourceName == "Anime News Network")
        // ANN's terms: their entry link travels with their row.
        #expect(candidates.first?.sourceURL != nil)
    }

    /// Fails before the merge with `sourceName == "MangaBaka"` for series 1
    /// (works was the only source) and no row at all for series 3.
    @Test("Per series the soonest date wins across both sources; works on a tie")
    func soonestAcrossSources() async throws {
        let repo = StubCacheRepository()
        repo.extrasByID[1] = SeriesExtras(volumes: [
            SeriesWork.Volume(number: "13", editions: [work(releaseDate: "2026-12-01")])
        ])
        repo.extrasByID[2] = SeriesExtras(volumes: [
            SeriesWork.Volume(number: "12", editions: [work(releaseDate: "2026-10-03")])
        ])
        let editions = try await store([
            1: annAnswer(12, "2026-10-03"), 2: annAnswer(12, "2026-10-03"), 3: annAnswer(5, "2026-11-01")
        ])
        let candidates = await WidgetSnapshot.nextVolumeCandidates(
            from: [libraryEntry(1, title: "ANN sooner"), libraryEntry(2, title: "Tie"),
                   libraryEntry(3, title: "Editions only")],
            repository: repo, editionAnswers: editions, now: now
        )
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.seriesID, $0) })
        #expect(byID[1]?.sourceName == "Anime News Network")
        #expect(byID[1]?.volumeLabel == "Vol. 12")
        #expect(byID[2]?.sourceName == "MangaBaka")
        #expect(byID[3]?.sourceName == "Anime News Network")
    }

    /// The numbers the morning note quotes. Fails before `coverage` existed
    /// with a compile error; the arithmetic is checked against a hand count:
    /// of four wanted entries, works answers two, editions answers two, one
    /// of those overlaps, and the dropped entry's hits count for nothing.
    @Test("Coverage counts works, editions and either over wanted entries only")
    func coverageCounts() {
        let entries = [
            libraryEntry(1, title: "Both"), libraryEntry(2, title: "Works only"),
            libraryEntry(3, title: "Editions only"), libraryEntry(4, title: "Neither"),
            libraryEntry(5, title: "Dropped", state: .dropped)
        ]
        let coverage = WidgetSnapshot.coverage(
            entries: entries, worksHits: [1, 2, 5], editionHits: [1, 3, 5]
        )
        #expect(coverage.works == 2)
        #expect(coverage.editions == 2)
        #expect(coverage.either == 3)
    }

    @Test("A series with no cached extras at all is skipped, not fetched")
    func noCacheIsSkipped() async {
        let repo = StubCacheRepository()
        let candidates = await WidgetSnapshot.nextVolumeCandidates(
            from: [libraryEntry(7, title: "Uncached")], repository: repo, now: now
        )
        #expect(candidates.isEmpty)
    }

    @Test("Cached works with no future date contribute nothing")
    func onlyPastWorksCachedIsSkipped() async {
        let repo = StubCacheRepository()
        repo.extrasByID[9] = SeriesExtras(volumes: [
            SeriesWork.Volume(number: "1", editions: [work(releaseDate: "2020-01-01")])
        ])
        let candidates = await WidgetSnapshot.nextVolumeCandidates(
            from: [libraryEntry(9, title: "Already published")], repository: repo, now: now
        )
        #expect(candidates.isEmpty)
    }

    @Test("Two forthcoming volumes for one series contribute only the sooner")
    func onlySoonestVolumePerSeries() async {
        let repo = StubCacheRepository()
        repo.extrasByID[3] = SeriesExtras(volumes: [
            SeriesWork.Volume(
                number: "13", editions: [work(releaseDate: "2026-12-01")]
            ),
            SeriesWork.Volume(
                number: "12", editions: [work(releaseDate: "2026-10-03")]
            )
        ])
        let candidates = await WidgetSnapshot.nextVolumeCandidates(
            from: [libraryEntry(3, title: "Two Forthcoming")], repository: repo, now: now
        )
        #expect(candidates.count == 1)
        #expect(candidates.first?.volumeLabel == "Vol. 12")
    }
}
