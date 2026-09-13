import Foundation
import Testing
@testable import MangaBaka

/// `WidgetSnapshot` is what the widget extension reads out of the App Group
/// container — a process with none of this target's entitlements, so these
/// tests exercise the pure parts (the JSON shape, and which entries each list
/// picks) rather than the file write itself, which no-ops without a
/// provisioned App Group (see `WidgetSnapshot.appGroupID`'s doc comment).
@Suite("Widget snapshot")
struct WidgetSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_789_000_000) // a Wednesday, 2026-09-09

    // MARK: - Round trip

    @Test("A snapshot round-trips through the same JSON shape the widget decodes")
    func roundTrips() throws {
        let snapshot = WidgetSnapshot(
            dueThisWeek: [
                WidgetSnapshot.Item(
                    seriesID: 1, title: "Tower of God", subtitle: "Due Thursday · Webtoons",
                    coverURL: URL(string: "https://example.com/cover.jpg")
                )
            ],
            pickBackUp: [
                WidgetSnapshot.Item(
                    seriesID: 2, title: "Solo Leveling", subtitle: "Ch. 88 of 200", coverURL: nil
                )
            ],
            writtenAt: now
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(snapshot)
        let decoded = try decoder.decode(WidgetSnapshot.self, from: data)

        #expect(decoded == snapshot)
    }

    // MARK: - dueThisWeekItems

    private func work(_ id: Int, _ title: String, dueIn days: Int) -> ScheduledWork {
        let due = now.addingTimeInterval(Double(days) * 86_400)
        let cadence = Cadence(
            medianGapDays: 7, spreadDays: 0, lastRelease: due.addingTimeInterval(-7 * 86_400),
            due: due, samples: 10, gaps: 9, isRegular: true
        )
        return ScheduledWork(series: SeriesFactory.make(id: id, title: title), cadence: cadence, reason: nil)
    }

    @Test("Due within seven days, soonest first; beyond the week does not appear")
    func dueThisWeekWindow() {
        let items = WidgetSnapshot.dueThisWeekItems(
            dated: [work(1, "Far", dueIn: 9), work(2, "Soon", dueIn: 1), work(3, "Later", dueIn: 5)],
            now: now
        )
        #expect(items.map(\.title) == ["Soon", "Later"])
    }

    @Test("Feed-sourced and estimated due dates merge into one date-sorted list")
    func feedAndEstimateMerge() {
        let feedWork = DueThisWeek.FeedDueWork(
            seriesId: 10, title: "Feed Series",
            due: now.addingTimeInterval(4 * 86_400), sourceName: "Webtoons"
        )
        let items = WidgetSnapshot.dueThisWeekItems(
            dated: [work(1, "Estimate Series", dueIn: 1)], feedWorks: [feedWork], now: now
        )
        // "Estimate Series" is due sooner (day 1) than "Feed Series" (day 4),
        // so the merged, date-sorted list puts it first — feed-sourced items
        // are preferred only when the same series has both, not raised above
        // an earlier-due series that has none.
        #expect(items.map(\.title) == ["Estimate Series", "Feed Series"])
        #expect(items.last?.subtitle.contains("Webtoons") == true)
    }

    @Test("No dated works and no feed works produce nothing, not a crash")
    func emptyIsEmpty() {
        #expect(WidgetSnapshot.dueThisWeekItems(dated: [], now: now).isEmpty)
    }

    // MARK: - pickBackUpItems

    private func entry(_ seriesId: Int, state: LibraryEntry.State, chapter: Double? = 10) -> LibraryEntry {
        LibraryEntry(
            id: seriesId, seriesId: seriesId, state: state, progressChapter: chapter, progressVolume: nil,
            rating: nil, note: nil, startDate: nil, finishDate: nil, numberOfRereads: nil, priority: nil,
            isPrivate: nil, readLink: nil, series: SeriesFactory.make(id: seriesId, title: "S\(seriesId)")
        )
    }

    @Test("Reading and not opened in 14 days qualifies; opened recently does not")
    func thresholdFilters() {
        let stale = entry(1, state: .reading)
        let fresh = entry(2, state: .reading)
        let items = WidgetSnapshot.pickBackUpItems(
            from: [stale, fresh],
            lastOpened: [
                1: now.addingTimeInterval(-20 * 86_400),
                2: now.addingTimeInterval(-1 * 86_400)
            ],
            now: now
        )
        #expect(items.map(\.seriesID) == [1])
    }

    @Test("Never opened on this device still qualifies")
    func neverOpenedQualifies() {
        let entryValue = entry(3, state: .reading)
        let items = WidgetSnapshot.pickBackUpItems(from: [entryValue], lastOpened: [:], now: now)
        #expect(items.map(\.seriesID) == [3])
    }

    @Test("A completed or plan-to-read entry is not a pick-back-up candidate")
    func onlyReadingQualifies() {
        let completed = entry(4, state: .completed)
        let planToRead = entry(5, state: .planToRead)
        let items = WidgetSnapshot.pickBackUpItems(
            from: [completed, planToRead], lastOpened: [:], now: now
        )
        #expect(items.isEmpty)
    }
}
