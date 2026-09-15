import Foundation

/// The "Next volume" list, in its own file for the lint's ceiling on
/// `WidgetSnapshot.swift`. Same rules as the two lists beside it: a pure
/// sort/window/cap step tested without I/O, and a gathering step that reads
/// only what the app already holds.
extension WidgetSnapshot {
    // MARK: - nextVolumeItems

    /// Next 60 days, soonest first, capped at six.
    ///
    /// **Both numbers are a guess.** 60 days rather than `dueThisWeekItems`'s
    /// 7: a chapter ships weekly and a week-wide window suits it, but a
    /// volume ships monthly to annually, and a 7-day window would leave the
    /// widget empty on most weeks even for a reader with real dates cached.
    /// Six matches `CoverLoader.maxCovers` — the medium family's three rows
    /// plus one to spare, with room left for the small widget's one row.
    static let nextVolumeWindowDays = 60
    static let nextVolumeCap = 6

    /// One row per series — its own earliest forthcoming volume, since
    /// `nextVolumeCandidates` already reduced each series to one candidate.
    /// Kept as a separate pure step (rather than folded into that gathering
    /// function) so the sort/window/cap rule can be tested without a
    /// repository stand-in, the same split `dueThisWeekItems` and
    /// `pickBackUpItems` already use.
    nonisolated static func nextVolumeItems(
        candidates: [NextVolumeEntry],
        now: Date = Date(),
        calendar: Calendar = .utc
    ) -> [NextVolumeEntry] {
        let today = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: nextVolumeWindowDays, to: today)
        else { return [] }
        var seen: Set<Int> = []
        var kept: [NextVolumeEntry] = []
        for candidate in candidates.sorted(by: { $0.date < $1.date }) {
            let day = calendar.startOfDay(for: candidate.date)
            guard day >= today, day < end, seen.insert(candidate.seriesID).inserted else { continue }
            kept.append(candidate)
            if kept.count == nextVolumeCap { break }
        }
        return kept
    }

    /// Every library series' next volume MangaBaka's own catalogue can show,
    /// cache-only — no request of any kind.
    ///
    /// **What this can and cannot see, measured 2026-09-14, and why.** The
    /// only source wired to a dated forthcoming volume that this widget can
    /// reach without a new network request is MangaBaka's own
    /// `/v1/series/{id}/works`, via `SeriesExtras.volumes` — because
    /// `SeriesRepository` already caches a whole series page's extras keyed
    /// by series id for six hours (`SeriesRepository+Cache.readDetailCache`),
    /// and `cachedExtras(for:)` reads that cache with no fetch at all, the
    /// same cache-only rule `DueThisWeekIntent.feedDueWorks` already follows
    /// for the Siri answer.
    ///
    /// The three catalogue legs behind the series page's own "Next volume"
    /// section — Anime News Network, Open Library, the National Diet Library
    /// (`SeriesDetailView+Editions.swift`) — are **not** usable here. Each
    /// client caches its own raw answer on disk (e.g. `ANNClient.readCache`),
    /// but the *merged*, de-duplicated `VolumeEditionAnswer` a series page
    /// actually draws is built by `VolumeEditions.merge(...)` at view time and
    /// held only in that view's own `@State` — nothing persists it keyed by
    /// series id. Reaching into each source's private cache file and
    /// re-running its dedupe and credit rules here would be a second, drifting
    /// copy of `VolumeEditionMerge.swift`'s judgement calls — the duplication
    /// this project's standards reject outright, not a shortcut around them.
    ///
    /// **The practical coverage this leaves:** a series appears here only if
    /// its detail page was opened in roughly the last six hours *and*
    /// MangaBaka's own works list carries a dated, not-yet-published volume
    /// for it — which, per `SeriesRepository+Cache.detailRowLimit` (200), is
    /// at most the 200 most recently viewed series pages, never "the whole
    /// library". A series never opened, or opened longer ago, contributes
    /// nothing, and the widget's empty state says so rather than implying the
    /// library has nothing coming.
    /// Which library states a "next volume" is worth a Home Screen slot for.
    ///
    /// Reading, rereading and paused: the reader would buy it. Completed and
    /// dropped: they would not, and a dropped series' volume 14 on the Home
    /// Screen is a nag. Plan-to-read and considering: not yet — they have not
    /// started, so the *next* volume is not a concept for them. Abdi's call,
    /// 2026-09-14 ("reading + on-hold only; dropped and completed out").
    nonisolated static func wantsNextVolume(_ state: LibraryEntry.State) -> Bool {
        switch state {
        case .reading, .rereading, .paused: true
        case .completed, .dropped, .planToRead, .considering: false
        }
    }

    static func nextVolumeCandidates(
        from entries: [LibraryEntry],
        repository: any SeriesRepositoryProtocol,
        now: Date = Date()
    ) async -> [NextVolumeEntry] {
        // One hop and one query for the whole library, not one per entry:
        // `SeriesRepository+Cache.cachedExtrasLinks` records what the
        // per-entry version cost on the launch path (939 hops), and this
        // walk is the same shape (night review, persistence §3).
        let wanted = entries.filter { Self.wantsNextVolume($0.state) }
        let volumesByID = await repository.cachedExtrasVolumes(for: wanted.map(\.seriesId))
        var candidates: [NextVolumeEntry] = []
        for entry in wanted {
            guard let series = entry.series, let volumes = volumesByID[entry.seriesId] else { continue }
            let soonest = volumes
                .compactMap { volume -> (SeriesWork.Volume, Date)? in
                    guard let date = volume.date, date > now else { return nil }
                    return (volume, date)
                }
                .min { $0.1 < $1.1 }
            guard let (volume, date) = soonest else { continue }
            candidates.append(NextVolumeEntry(
                seriesID: entry.seriesId,
                title: series.displayTitle ?? "Untitled series",
                volumeLabel: volume.label,
                date: date,
                coverURL: volume.cover.flatMap(Self.widgetCover) ?? Self.widgetCover(series.cover),
                sourceName: "MangaBaka",
                sourceURL: nil
            ))
        }
        return candidates
    }
}
