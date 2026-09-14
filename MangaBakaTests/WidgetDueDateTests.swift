import Testing
import Foundation
@testable import MangaBaka

/// Item 13: the widget's "Due Thursday" was a string baked at snapshot-write
/// time with the `Date` thrown away, so it kept naming a day that had passed
/// while the hourly timeline reload made it look freshly computed.
///
/// The date is now carried as `WidgetSnapshot.Item.due` and the weekday is
/// formatted in the widget's own provider
/// (`SeriesWidgetEntryBuilder.subtitle(for:)`, in the extension target, which
/// this target cannot import). What is testable here is the half that
/// produces the data: the date survives, and the stale string does not.
@Suite("Widget due dates survive as dates")
struct WidgetDueDateTests {
    private let now = Date(timeIntervalSince1970: 1_757_000_000)

    private func work(_ id: Int, _ title: String, dueIn days: Int) -> ScheduledWork {
        let due = now.addingTimeInterval(Double(days) * 86_400)
        let cadence = Cadence(
            medianGapDays: 7, spreadDays: 0, lastRelease: due.addingTimeInterval(-7 * 86_400),
            due: due, samples: 10, gaps: 9, isRegular: true
        )
        return ScheduledWork(series: SeriesFactory.make(id: id, title: title), cadence: cadence, reason: nil)
    }

    /// Expected failure before the fix: `WidgetSnapshot.Item` has no `due`
    /// property at all, so this does not compile; the subtitle it did carry
    /// was "Due Thursday", which is what went stale.
    @Test("An estimated due row carries its date, and no baked weekday")
    func estimatedRowCarriesTheDate() {
        let items = WidgetSnapshot.dueThisWeekItems(dated: [work(1, "Soon", dueIn: 2)], now: now)
        let row = items.first

        #expect(row?.due != nil, "the widget formats the weekday from this, now, not from a string")
        #expect(row?.subtitle.isEmpty == true, "nothing that can go stale is in the subtitle")
        #expect(row?.subtitle.contains("Due") != true)
    }

    /// A feed-sourced row keeps the one thing about it that cannot go stale —
    /// which publisher said so — and nothing else.
    @Test("A feed-sourced due row carries its date and only the source's name")
    func feedRowCarriesSourceOnly() {
        let feedWork = DueThisWeek.FeedDueWork(
            seriesId: 10, title: "Feed Series",
            due: now.addingTimeInterval(3 * 86_400), sourceName: "Webtoons"
        )
        let items = WidgetSnapshot.dueThisWeekItems(dated: [], feedWorks: [feedWork], now: now)

        #expect(items.first?.subtitle == "Webtoons")
        #expect(items.first?.due != nil)
    }

    /// Item 109. Four `raw` covers at 1,200x1,800 are roughly 8 MB each once
    /// decoded, against a widget extension's memory ceiling in the low tens of
    /// MB — a nil cover and a grey placeholder beat a jetsam that takes the
    /// whole timeline with it.
    ///
    /// Expected failure before the fix: `coverURL` is the `raw` URL, because
    /// the chain was `x250 ?? x350 ?? raw`.
    @Test("A cover with only a raw URL is not sent to the widget at all")
    func rawOnlyCoversAreDropped() throws {
        let raw = try #require(URL(string: "https://example.com/raw.jpg"))
        let cover = Cover(
            raw: raw, x150: nil, x250: nil, x350: nil,
            blurhash: nil, width: 1200, height: 1800
        )
        let series = SeriesFactory.make(id: 5, title: "Raw Only", cover: cover)
        let entry = LibraryEntry(
            id: 5, seriesId: 5, state: .reading, progressChapter: 10,
            progressVolume: nil, rating: nil, note: nil, startDate: nil,
            finishDate: nil, numberOfRereads: nil, priority: nil, isPrivate: nil,
            readLink: nil, series: series
        )

        let items = WidgetSnapshot.pickBackUpItems(from: [entry], lastOpened: [:], now: now)
        #expect(items.count == 1, "control: the row itself is still built")
        #expect(items.first?.coverURL == nil)
    }
}
