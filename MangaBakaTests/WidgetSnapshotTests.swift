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

    // MARK: - The cross-target contract

    /// The app writes `WidgetSnapshot`; the extension reads `WidgetSnapshotData`,
    /// a separate `Codable` in a target this bundle does not link. Until
    /// 2026-09-14 this test encoded and decoded `WidgetSnapshot` on both sides,
    /// which proved nothing about the pair: renaming `dueThisWeek` on one side
    /// only would have passed here, both targets would have built, and — because
    /// `WidgetSnapshotData`'s two lists default to `[]` — the extension would have
    /// decoded the file happily and drawn "Open MangaBaka to load" forever.
    /// `WidgetSnapshotData.swift` is now compiled into this target (`project.yml`)
    /// so the decode below crosses the seam it is named for.
    @Test("The app's bytes decode into the type the widget extension actually uses")
    func appBytesDecodeAsWidgetData() throws {
        let snapshot = Self.sampleSnapshot(now: now)

        let data = try Self.appEncoder.encode(snapshot)
        let widgetSide = try Self.widgetDecoder.decode(WidgetSnapshotData.self, from: data)

        // Values, not just "it decoded". A renamed field on the app side leaves
        // the matching list empty rather than throwing, so only comparing
        // contents can fail on it.
        #expect(widgetSide.dueThisWeek.map(\.seriesID) == [1])
        #expect(widgetSide.dueThisWeek.map(\.title) == ["Tower of God"])
        #expect(widgetSide.dueThisWeek.map(\.subtitle) == ["Webtoons"])
        #expect(widgetSide.dueThisWeek.first?.coverURL
            == URL(string: "https://example.com/cover.jpg"))
        // `due` is the whole point of the 2026-09-14 change and was the one
        // field neither contract test crossed the seam with: the app ships a
        // `Date`, the widget formats the weekday freshly
        // (`SeriesWidgetEntryBuilder.subtitle(for:)`) and drops rows whose day
        // has passed. Rename it on the app side and every widget silently
        // reverts to a bare subtitle with no past-due filtering — which is
        // exactly the failure this suite exists to catch.
        #expect(widgetSide.dueThisWeek.first?.due == Self.sampleDue)
        // And the other half of the contract: a row with no `due` decodes to
        // nil rather than throwing, which is what lets an old snapshot survive
        // an app update.
        #expect(widgetSide.pickBackUp.first?.due == nil)
        #expect(widgetSide.pickBackUp.map(\.seriesID) == [2])
        #expect(widgetSide.pickBackUp.map(\.title) == ["Solo Leveling"])
        #expect(widgetSide.pickBackUp.map(\.subtitle) == ["Ch. 88 of 200"])
        #expect(widgetSide.pickBackUp.first?.coverURL == nil)
        #expect(widgetSide.writtenAt == now)
    }

    /// The wire names themselves, spelled out once. The decode above catches a
    /// one-sided rename; this catches a *matched* rename, which is the case
    /// where a widget already on someone's Home Screen (drawn by the installed
    /// extension) meets a newly-updated app before the extension is replaced.
    /// It is also the cheaper failure to read: it names the key that moved.
    @Test("The JSON keys and the date format are the ones the widget decodes")
    func encodedKeysAreTheContract() throws {
        let data = try Self.appEncoder.encode(Self.sampleSnapshot(now: now))
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(Set(object.keys) == ["dueThisWeek", "pickBackUp", "nextVolumes", "writtenAt"])

        let items = try #require(object["dueThisWeek"] as? [[String: Any]])
        #expect(items.count == 1)
        let firstItem = try #require(items.first)
        #expect(Set(firstItem.keys) == ["seriesID", "title", "subtitle", "coverURL", "due"])

        // The `pickBackUp` row has no `due` and no cover. Asserted as "no real
        // value", not as an exact key set: whether the encoder omits an
        // Optional or writes null is not the app's promise to the extension
        // (see `nilCoverCrosses`), and pinning it here would fail on a change
        // that breaks nothing.
        let pickBackUp = try #require(object["pickBackUp"] as? [[String: Any]])
        let pickBackUpItem = try #require(pickBackUp.first)
        #expect(pickBackUpItem["due"] as? String == nil)

        // The item date uses the same ISO-8601 strategy as `writtenAt`; a
        // per-type strategy is not a thing `JSONEncoder` has, but a change to
        // the encoder's would break `due` silently where it breaks `writtenAt`
        // loudly, so both are named.
        #expect(firstItem["due"] as? String == ISO8601DateFormatter().string(from: Self.sampleDue))

        // ISO-8601, not the `Double` `JSONEncoder` defaults to. The widget's
        // decoder is `.iso8601`; a strategy change on the app side alone makes
        // every read fail and the widget has no way to report it.
        let writtenAt = try #require(object["writtenAt"] as? String)
        #expect(writtenAt == ISO8601DateFormatter().string(from: now))
    }

    /// An item with no cover: `coverURL` is `URL?`, and whether the encoder
    /// writes `null` or omits the key decides nothing here — `WidgetSnapshotData`
    /// must cope either way, because the app's encoder settings are not the
    /// extension's to choose.
    @Test("A missing cover URL survives the crossing")
    func nilCoverCrosses() throws {
        let data = try Self.appEncoder.encode(Self.sampleSnapshot(now: now))
        let widgetSide = try Self.widgetDecoder.decode(WidgetSnapshotData.self, from: data)
        #expect(widgetSide.pickBackUp.first?.coverURL == nil)
    }

    /// Both processes' coders, spelled the way each really spells them:
    /// `WidgetSnapshot.encoder` (app) and `WidgetSnapshotData.read()` (widget)
    /// are both private, so these mirror them. If either private property
    /// changes strategy, `encodedKeysAreTheContract` is what notices.
    private static var appEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var widgetDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The Thursday after `now`'s Wednesday, as `dueThisWeekItems` would write
    /// it: `calendar.startOfDay`, so a whole day and not a moment inside one.
    private static let sampleDue = Date(timeIntervalSince1970: 1_789_000_000 + 86_400)

    /// The `dueThisWeek` row carries a real `due`; the `pickBackUp` row
    /// deliberately does not, so the "an older app's snapshot with no key still
    /// decodes" promise at `WidgetSnapshotData.Item.due` is covered by the same
    /// fixture.
    ///
    /// Its subtitle is what `WidgetSnapshot.dueThisWeekItems` really writes —
    /// the feed's name alone (`:184-187`). Until 2026-09-14 it read
    /// "Due Thursday · Webtoons", a string the app stopped producing when the
    /// weekday moved out of `subtitle` and into `due`; a fixture that
    /// contradicts the model it is built from cannot fail on a change to it.
    private static func sampleSnapshot(now: Date) -> WidgetSnapshot {
        WidgetSnapshot(
            dueThisWeek: [
                WidgetSnapshot.Item(
                    seriesID: 1, title: "Tower of God", subtitle: "Webtoons",
                    coverURL: URL(string: "https://example.com/cover.jpg"),
                    due: sampleDue
                )
            ],
            pickBackUp: [
                WidgetSnapshot.Item(
                    seriesID: 2, title: "Solo Leveling", subtitle: "Ch. 88 of 200", coverURL: nil
                )
            ],
            writtenAt: now
        )
    }

    /// Not a contract test, despite sitting under that heading for a day:
    /// both sides here are `WidgetSnapshot`, so it catches a self-inconsistent
    /// `Codable` and nothing about the extension. Named for what it does —
    /// the suite comment above says why the distinction matters.
    @Test("The app's own snapshot type is self-consistent through JSON")
    func appTypeIsSelfConsistent() throws {
        let snapshot = Self.sampleSnapshot(now: now)
        let data = try Self.appEncoder.encode(snapshot)
        let decoded = try Self.widgetDecoder.decode(WidgetSnapshot.self, from: data)
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
