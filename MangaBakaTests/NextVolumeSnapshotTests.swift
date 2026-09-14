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
        // Nothing here is ANN-sourced — see the doc comment on
        // `nextVolumeCandidates` for why the ANN/Open Library/NDL legs are
        // not reachable from a cache-only gather.
        #expect(candidates.first?.sourceURL == nil)
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

    // MARK: - The cross-target contract, extended for nextVolumes

    /// Mirrors `WidgetSnapshotTests.appBytesDecodeAsWidgetData`: proves the
    /// app's bytes decode into the type the widget extension actually reads,
    /// now including `nextVolumes`. Expected to fail before
    /// `WidgetSnapshotData.NextVolumeEntry` existed with a compile error —
    /// the widget target had no field to decode this into at all.
    @Test("nextVolumes crosses into the type the widget extension uses")
    func nextVolumesCrossesTheSeam() throws {
        let entry = WidgetSnapshot.NextVolumeEntry(
            seriesID: 42, title: "Delicious in Dungeon", volumeLabel: "Vol. 12",
            date: now, coverURL: URL(string: "https://example.com/cover.jpg"),
            sourceName: "MangaBaka", sourceURL: nil
        )
        let snapshot = WidgetSnapshot(nextVolumes: [entry], writtenAt: now)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let widgetSide = try decoder.decode(WidgetSnapshotData.self, from: data)

        #expect(widgetSide.nextVolumes.map(\.seriesID) == [42])
        #expect(widgetSide.nextVolumes.map(\.title) == ["Delicious in Dungeon"])
        #expect(widgetSide.nextVolumes.map(\.volumeLabel) == ["Vol. 12"])
        #expect(widgetSide.nextVolumes.first?.date == now)
        #expect(widgetSide.nextVolumes.first?.coverURL == URL(string: "https://example.com/cover.jpg"))
        #expect(widgetSide.nextVolumes.first?.sourceName == "MangaBaka")
        #expect(widgetSide.nextVolumes.first?.sourceURL == nil)
    }

    /// Expected to fail before `WidgetSnapshot.init(from:)` was hand-written
    /// with: `DecodingError.keyNotFound` for `nextVolumes` — a plain
    /// `= []`-defaulted stored property is not consulted by Foundation's
    /// synthesized `Decodable` for a missing key (measured with a throwaway
    /// `Codable` struct, see `WidgetSnapshot.init(from:)`'s doc comment), so
    /// before the hand-written decoder this JSON — exactly what an older
    /// build of the app actually wrote — would have failed the whole decode,
    /// not just left `nextVolumes` empty.
    @Test("A snapshot written before nextVolumes existed still decodes")
    func oldSnapshotStillDecodes() throws {
        let json = """
            {
                "dueThisWeek": [],
                "pickBackUp": [],
                "writtenAt": "\(ISO8601DateFormatter().string(from: now))"
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WidgetSnapshot.self, from: Data(json.utf8))
        #expect(decoded.nextVolumes.isEmpty)
        #expect(decoded.writtenAt == now)

        // Control: the same file decodes on the widget side too, which reads
        // a separate `Codable` type compiled into a different target.
        let widgetSide = try decoder.decode(WidgetSnapshotData.self, from: Data(json.utf8))
        #expect(widgetSide.nextVolumes.isEmpty)
    }
}
