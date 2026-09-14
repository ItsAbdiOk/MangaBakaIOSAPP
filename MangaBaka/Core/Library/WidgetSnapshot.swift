import Foundation
import WidgetKit

/// Everything a Home Screen widget shows, written to the App Group container
/// so the widget extension — a separate process with no access to the app's
/// own sandboxed container, database, or `URLCache` — has something to read.
///
/// A widget's `TimelineProvider` runs on the system's own schedule, not the
/// app's, so this is written eagerly by the app itself right after the two
/// pipelines that produce its contents finish: the library walk (for
/// `pickBackUp`) and a schedule build (for `dueThisWeek`). `write(...)` merges
/// rather than replaces, because those two finish independently and neither
/// should blank out what the other already wrote.
///
/// Kept to exactly what the widget draws — a title, one subtitle line, and a
/// cover URL — so a change to how `Series` or `ScheduledWork` are shaped
/// elsewhere in the app cannot silently break the widget's JSON decode.
struct WidgetSnapshot: Codable, Sendable, Equatable {
    struct Item: Codable, Sendable, Equatable, Identifiable, Hashable {
        let seriesID: Int
        let title: String
        /// e.g. "Ch. 88 of 120" for a `pickBackUp` row, or the feed's name
        /// ("Webtoons") for a `dueThisWeek` row that has one — empty for a
        /// MangaUpdates estimate, which has nothing to name.
        ///
        /// No longer carries the weekday: see `due` below, and
        /// `SeriesWidgetEntryBuilder.subtitle(for:)`, which composes the two.
        /// A chapter number is still baked here, for the reason
        /// `SpotlightIndex.description(for:)` bakes its own — it cannot go
        /// stale, where a date can.
        let subtitle: String
        let coverURL: URL?
        /// The day this row is actually due, for a `dueThisWeek` row; nil for
        /// `pickBackUp`, which has no date.
        ///
        /// The widget formats the weekday from this rather than reading it out
        /// of `subtitle`. Until 2026-09-14 the weekday was baked into
        /// `subtitle` and the `Date` was thrown away, so a snapshot written
        /// during the last manual schedule build kept saying "Due Thursday"
        /// into the following week — and the hourly timeline reload made that
        /// look freshly computed. `var` with a default only so the memberwise
        /// initialiser stays source-compatible for `pickBackUp` rows; nothing
        /// mutates it.
        var due: Date?

        var id: Int { seriesID }
    }

    /// One upcoming volume the "Next volume" widget can show.
    ///
    /// See `nextVolumeCandidates(from:repository:now:)` for exactly which
    /// series this can and cannot cover, and why. `Codable` fields only — no
    /// derived properties — because this crosses to `WidgetSnapshotData` the
    /// same way `Item` does, decoded by a target that does not link this file.
    struct NextVolumeEntry: Codable, Sendable, Equatable, Identifiable, Hashable {
        let seriesID: Int
        let title: String
        /// "Vol. 12", or "Other editions" — `SeriesWork.Volume.label` as-is,
        /// never re-derived here.
        let volumeLabel: String
        /// UTC midnight, matching `Item.due` — a release date is a calendar
        /// day, not an instant, and `SeriesWork.date` is already parsed that
        /// way (`SeriesWork.formatter`, fixed to `secondsFromGMT: 0`).
        let date: Date
        let coverURL: URL?
        /// Which catalogue said this. Always "MangaBaka" today — see
        /// `nextVolumeCandidates`'s doc comment for why the ANN/Open
        /// Library/NDL legs behind the series page's own "Next volume"
        /// section are not reachable from here.
        let sourceName: String
        /// Non-nil only when `sourceName` is Anime News Network: their API
        /// terms require a link to the specific entry on any page showing
        /// their details (`VolumeCatalogue.requiresPerEntryLink`). Carried
        /// now so a future ANN-sourced candidate needs no shape change —
        /// always nil today, since nothing here is ANN-sourced yet.
        let sourceURL: URL?

        var id: Int { seriesID }
    }

    var dueThisWeek: [Item] = []
    var pickBackUp: [Item] = []
    var nextVolumes: [NextVolumeEntry] = []
    var writtenAt: Date

    private enum CodingKeys: String, CodingKey {
        case dueThisWeek, pickBackUp, nextVolumes, writtenAt
    }

    /// Written out because a hand-rolled `init(from:)` (below) suppresses the
    /// synthesized memberwise initialiser, and every call site in this app —
    /// `write(...)`, `clear(...)`, the tests — constructs this positionally by
    /// name. `dueThisWeek`/`pickBackUp`/`nextVolumes` all default to `[]` so a
    /// caller that only has a date (`clock.now` in `write`) keeps compiling.
    init(
        dueThisWeek: [Item] = [],
        pickBackUp: [Item] = [],
        nextVolumes: [NextVolumeEntry] = [],
        writtenAt: Date
    ) {
        self.dueThisWeek = dueThisWeek
        self.pickBackUp = pickBackUp
        self.nextVolumes = nextVolumes
        self.writtenAt = writtenAt
    }

    /// Tolerant of a snapshot written before `nextVolumes` existed.
    ///
    /// **Measured, not assumed, 2026-09-14:** Foundation's synthesized
    /// `Decodable` does *not* fall back to a stored property's default value
    /// for a missing key, even when the property is non-Optional with a `= []`
    /// default — verified with a throwaway `Codable` struct decoding `{}`
    /// against a `var list: [Int] = []` field, which threw `keyNotFound`
    /// rather than producing `[]`. So the plain `Codable` conformance this
    /// type had before today would have thrown on every snapshot written by
    /// an older build the instant `nextVolumes` was added as a plain stored
    /// property, and `read()`'s `try?` would have turned that into "no
    /// snapshot at all" — silently discarding a perfectly good `dueThisWeek`
    /// and `pickBackUp` list along with it. `decodeIfPresent(...) ?? []` here
    /// is what actually keeps an old file readable — the same reasoning
    /// `EditionVolume.init(from:)` already applies to `alsoFrom`/`dateFrom`.
    ///
    /// `dueThisWeek` and `pickBackUp` stay required keys: every snapshot this
    /// app has ever written carries both, so a decode failure on either means
    /// a genuinely corrupt file, and failing loudly (to `nil`, via the
    /// caller's `try?`) is correct there in a way it is not for a key that
    /// simply predates this field.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dueThisWeek = try container.decode([Item].self, forKey: .dueThisWeek)
        pickBackUp = try container.decode([Item].self, forKey: .pickBackUp)
        nextVolumes = try container.decodeIfPresent([NextVolumeEntry].self, forKey: .nextVolumes) ?? []
        writtenAt = try container.decode(Date.self, forKey: .writtenAt)
    }

    /// The App Group both the app and `MangaBakaWidgets` are entitled to.
    ///
    /// **A guess at signing, not at the spelling** — the identifier mirrors
    /// `PRODUCT_BUNDLE_IDENTIFIER`'s own prefix (`dev.abdirahmanmohamed.mangabaka`),
    /// which is exact. What is unconfirmed is provisioning: App Groups is a
    /// capability the profile must carry, and if Xcode Cloud's first archive
    /// fails on entitlements, the fix is enabling "App Groups" for this App ID
    /// in the developer portal — automatic signing on a local build adds it
    /// without asking, but Xcode Cloud does not carry that same door.
    static let appGroupID = "group.dev.abdirahmanmohamed.mangabaka"

    private static let fileName = "widget-snapshot.json"

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Merges whichever of the two lists changed into whatever is already on
    /// disk, so the library walk finishing does not blank out the last
    /// schedule build's `dueThisWeek` (or vice versa), and asks WidgetKit to
    /// redraw every widget on the Home Screen.
    ///
    /// Silent on failure — a missing App Group entitlement or a full disk
    /// leaves the widget showing whatever it last had (or the "Open
    /// MangaBaka to load" placeholder on a fresh install), rather than the
    /// app surfacing an error for a screen it does not own.
    static func write(
        dueThisWeek: [Item]? = nil,
        pickBackUp: [Item]? = nil,
        nextVolumes: [NextVolumeEntry]? = nil,
        clock: any Clock = SystemClock()
    ) {
        guard let containerURL else { return }
        let existing = read()
        var snapshot = existing ?? WidgetSnapshot(writtenAt: clock.now)
        if let dueThisWeek { snapshot.dueThisWeek = dueThisWeek }
        if let pickBackUp { snapshot.pickBackUp = pickBackUp }
        if let nextVolumes { snapshot.nextVolumes = nextVolumes }
        // Whether any list actually moved. `writtenAt` is excluded
        // deliberately, since it always differs.
        let changed = existing == nil
            || existing?.dueThisWeek != snapshot.dueThisWeek
            || existing?.pickBackUp != snapshot.pickBackUp
            || existing?.nextVolumes != snapshot.nextVolumes

        // The file is still rewritten either way: `writtenAt` is how the
        // widget knows whether what it is showing was computed recently
        // enough to trust (`SeriesWidgetEntryBuilder.makeEntry`), and
        // withholding the write on a no-op would make an up-to-date snapshot
        // age into the "Open MangaBaka to refresh" placeholder. A few KB to
        // the App Group container costs nothing.
        snapshot.writtenAt = clock.now
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: containerURL.appendingPathComponent(fileName), options: .atomic)

        // The reload is the part that is rationed. WidgetKit documents a
        // budget of roughly 40-70 reloads per widget per day, and this asked
        // for one on every launch whether or not either list had moved — so
        // the one reload that matters (the schedule build that produced a new
        // date) is the one the system can end up deferring.
        guard changed else { return }
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Empties the snapshot and redraws, for an account change.
    ///
    /// Sign-out forgot the library, the ranker, the reminders and the
    /// Spotlight index and left this file alone, so the previous account's
    /// "Pick back up · Ch. 88 of 120" stayed on the Home Screen — with working
    /// deep links into a library the app no longer has. Call it beside
    /// `spotlight.clear()`.
    ///
    /// Writes rather than deletes: a missing file is the fresh-install case
    /// the widget draws as "Open MangaBaka to load", which is the right thing
    /// to show, and an empty written snapshot says the same while leaving the
    /// container in a state `write(...)` can merge into.
    static func clear(clock: any Clock = SystemClock()) {
        guard let containerURL else { return }
        let empty = WidgetSnapshot(dueThisWeek: [], pickBackUp: [], nextVolumes: [], writtenAt: clock.now)
        guard let data = try? encoder.encode(empty) else { return }
        try? data.write(to: containerURL.appendingPathComponent(fileName), options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// What the widget extension reads. Nil before the app has ever written
    /// (fresh install) or if the file cannot be read or decoded — both cases
    /// the provider shows as the placeholder rather than an error, since a
    /// widget has no way to retry on its own.
    static func read() -> WidgetSnapshot? {
        guard let containerURL,
              let data = try? Data(contentsOf: containerURL.appendingPathComponent(fileName))
        else { return nil }
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    // MARK: - Building the two lists

    /// Due within the next seven days, soonest first — feed-sourced real
    /// dates (`DueThisWeekIntent.feedDueWorks`) ahead of MangaUpdates
    /// estimates for the same window, matching the order `DueThisWeek`
    /// speaks them in so the widget and Siri never disagree about what is
    /// due first.
    /// - Parameter calendar: UTC, not the device's. A `Cadence.due` is
    ///   derived from MangaUpdates release dates, which are UTC midnights;
    ///   `Calendar.current.startOfDay` moves every one of them to the previous
    ///   local day west of UTC. See `Calendar.utc`.
    static func dueThisWeekItems(
        dated: [ScheduledWork],
        feedWorks: [DueThisWeek.FeedDueWork] = [],
        now: Date = Date(),
        calendar: Calendar = .utc
    ) -> [Item] {
        let today = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: DueThisWeek.window, to: today) else { return [] }

        var seen: Set<Int> = []
        var items: [(item: Item, due: Date)] = []

        for work in feedWorks.sorted(by: { $0.due < $1.due }) {
            let day = calendar.startOfDay(for: work.due)
            guard day < end, seen.insert(work.seriesId).inserted else { continue }
            items.append((
                Item(
                    seriesID: work.seriesId, title: work.title,
                    subtitle: work.sourceName, coverURL: work.coverURL, due: day
                ),
                day
            ))
        }

        let sortedDated = dated
            .compactMap { work -> (ScheduledWork, Date)? in
                guard let cadence = work.cadence else { return nil }
                return (work, calendar.startOfDay(for: cadence.due))
            }
            .sorted { $0.1 < $1.1 }
        for (work, day) in sortedDated {
            guard day < end, seen.insert(work.series.id).inserted else { continue }
            items.append((
                Item(
                    seriesID: work.series.id,
                    title: work.series.displayTitle ?? "Untitled series",
                    subtitle: "",
                    coverURL: Self.widgetCover(work.series.cover),
                    due: day
                ),
                day
            ))
        }

        return items.sorted { $0.due < $1.due }.map(\.item)
    }

    /// **A guess at the threshold** — fourteen days chosen because it is
    /// roughly two weeks of ordinary reading without an obvious measurement
    /// to derive it from. Reading, and either never opened on this device or
    /// not opened in at least that long — a series opened yesterday is not
    /// something the reader needs reminding of.
    static let pickBackUpThreshold: TimeInterval = 14 * 86_400

    /// - Parameter lastOpened: from `HistoryStore`, keyed by series id. A
    ///   series with no entry has never been opened on this device and is
    ///   treated as eligible, the same as one opened long enough ago.
    static func pickBackUpItems(
        from entries: [LibraryEntry],
        lastOpened: [Int: Date],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Item] {
        entries
            .filter { $0.state == .reading }
            .compactMap { entry -> (Item, Date)? in
                let opened = lastOpened[entry.seriesId]
                if let opened, now.timeIntervalSince(opened) < pickBackUpThreshold { return nil }
                guard let series = entry.series else { return nil }
                let subtitle: String
                if let chapter = entry.progressChapter, chapter > 0 {
                    let total = series.totalChapters.map { " of \(Int(wholeOrClamped: $0))" } ?? ""
                    subtitle = "Ch. \(Int(wholeOrClamped: chapter))\(total)"
                } else {
                    subtitle = "Pick back up"
                }
                let item = Item(
                    seriesID: entry.seriesId,
                    title: series.displayTitle ?? "Untitled series",
                    subtitle: subtitle,
                    coverURL: Self.widgetCover(series.cover)
                )
                // Never-opened entries sort last: there is no date to rank
                // them by, and a series the reader has actually let sit is a
                // stronger "pick this back up" candidate than one with no
                // signal either way.
                return (item, opened ?? .distantPast)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// The largest cover a widget row should ever download.
    ///
    /// `raw` is deliberately not a fallback. The extension decodes up to four
    /// of these with `UIImage(data:)` inside `getTimeline`, against a memory
    /// ceiling in the low tens of MB; four `raw` covers at 1,200x1,800 are
    /// roughly 8 MB each decoded, which is a jetsam rather than a widget. A
    /// grey placeholder in a 32x44 slot is a far smaller loss than the whole
    /// extension being killed — and the timeline it was building with it.
    static func widgetCover(_ cover: Cover) -> URL? {
        cover.x250 ?? cover.x350
    }
}
