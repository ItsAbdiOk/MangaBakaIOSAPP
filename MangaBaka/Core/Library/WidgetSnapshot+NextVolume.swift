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

    /// Every library series' next volume the app already holds a date for,
    /// cache-only — no request of any kind.
    ///
    /// **Two sources, merged per series.** MangaBaka's own
    /// `/v1/series/{id}/works`, via `SeriesExtras.volumes` — because
    /// `SeriesRepository` already caches a whole series page's extras keyed
    /// by series id for six hours (`SeriesRepository+Cache.readDetailCache`),
    /// and `cachedExtras(for:)` reads that cache with no fetch at all, the
    /// same cache-only rule `DueThisWeekIntent.feedDueWorks` already follows
    /// for the Siri answer. And, since 2026-09-15, the merged Anime News
    /// Network / Open Library / National Diet Library answer the series page
    /// drew (`SeriesDetailView+Editions.swift`), which `EditionAnswerStore`
    /// keeps for 30 days keyed by series id. Per series the soonest date
    /// wins; on a tie MangaBaka's own row is preferred, because it carries a
    /// volume cover and owes no third party a per-row link.
    ///
    /// **What this could not see before, measured 2026-09-14, and why.** The
    /// three catalogue legs were not reachable from here: each client caches
    /// its own raw answer on disk (e.g. `ANNClient.readCache`), but the
    /// *merged*, de-duplicated `VolumeEditionAnswer` a series page actually
    /// draws was built by `VolumeEditions.merge(...)` at view time and held
    /// only in that view's own `@State` — nothing persisted it keyed by
    /// series id. Reaching into each source's private cache file and
    /// re-running its dedupe and credit rules here would have been a second,
    /// drifting copy of `VolumeEditionMerge.swift`'s judgement calls — the
    /// duplication this project's standards reject outright. Persisting the
    /// merged answer once, where it is built, is what made the second source
    /// possible without that copy.
    ///
    /// **The practical coverage this leaves:** the MangaBaka leg still sees a
    /// series only if its detail page was opened in roughly the last six
    /// hours *and* its works list carries a dated, not-yet-published volume —
    /// at most the 200 most recently viewed pages
    /// (`SeriesRepository+Cache.detailRowLimit`). The editions leg sees a
    /// page opened in the last 30 days, up to `EditionAnswerStore.rowLimit`
    /// (300). A series never opened contributes nothing, and the widget's
    /// empty state says so rather than implying the library has nothing
    /// coming. `coverage(entries:worksHits:editionHits:)` counts the three
    /// sets so a note can quote them.
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
        editionAnswers: EditionAnswerStore? = nil,
        now: Date = Date()
    ) async -> [NextVolumeEntry] {
        // One hop and one query per source for the whole library, not one
        // per entry: `SeriesRepository+Cache.cachedExtrasLinks` records what
        // the per-entry version cost on the launch path (939 hops), and this
        // walk is the same shape (night review, persistence §3).
        let wanted = entries.filter { Self.wantsNextVolume($0.state) }
        let ids = wanted.map(\.seriesId)
        let volumesByID = await repository.cachedExtrasVolumes(for: ids)
        let editionsByID = await editionAnswers?.forthcoming(for: ids) ?? [:]
        var candidates: [NextVolumeEntry] = []
        for entry in wanted {
            guard let series = entry.series else { continue }
            let fromWorks = volumesByID[entry.seriesId].flatMap {
                Self.worksCandidate(entry: entry, series: series, volumes: $0, now: now)
            }
            let fromEditions = editionsByID[entry.seriesId].map {
                Self.editionCandidate(entry: entry, series: series, forthcoming: $0)
            }
            if let candidate = Self.soonest(works: fromWorks, editions: fromEditions) {
                candidates.append(candidate)
            }
        }
        return candidates
    }

    /// Soonest date wins; MangaBaka's `works` row on a tie (see the doc
    /// comment on `nextVolumeCandidates` for why).
    nonisolated static func soonest(
        works: NextVolumeEntry?, editions: NextVolumeEntry?
    ) -> NextVolumeEntry? {
        switch (works, editions) {
        case let (work?, edition?): edition.date < work.date ? edition : work
        case let (work?, nil): work
        case let (nil, edition?): edition
        case (nil, nil): nil
        }
    }

    /// How many of the wanted entries each source could answer, and how many
    /// either could. `worksHits` and `editionHits` are the key sets the two
    /// one-query reads returned; entries outside `wantsNextVolume` are not
    /// counted, since neither source is asked about them.
    nonisolated static func coverage(
        entries: [LibraryEntry], worksHits: Set<Int>, editionHits: Set<Int>
    ) -> Coverage {
        let wanted = Set(entries.filter { Self.wantsNextVolume($0.state) }.map(\.seriesId))
        return Coverage(
            works: wanted.intersection(worksHits).count,
            editions: wanted.intersection(editionHits).count,
            either: wanted.intersection(worksHits.union(editionHits)).count
        )
    }

    /// The three counts `coverage` answers — a struct rather than a tuple for
    /// the lint, and so the morning note can name the fields.
    struct Coverage: Equatable, Sendable {
        let works: Int
        let editions: Int
        let either: Int
    }

    private static func worksCandidate(
        entry: LibraryEntry, series: Series, volumes: [SeriesWork.Volume], now: Date
    ) -> NextVolumeEntry? {
        let soonest = volumes
            .compactMap { volume -> (SeriesWork.Volume, Date)? in
                guard let date = volume.date, date > now else { return nil }
                return (volume, date)
            }
            .min { $0.1 < $1.1 }
        guard let (volume, date) = soonest else { return nil }
        return NextVolumeEntry(
            seriesID: entry.seriesId,
            title: series.displayTitle ?? "Untitled series",
            volumeLabel: volume.label,
            date: date,
            coverURL: volume.cover.flatMap(Self.widgetCover) ?? Self.widgetCover(series.cover),
            sourceName: "MangaBaka",
            sourceURL: nil
        )
    }

    /// The catalogue row carries no cover; the series' own is used. The
    /// source name and URL travel with the entry because ANN's terms want a
    /// link to their entry wherever their data is shown
    /// (`VolumeCatalogue.requiresPerEntryLink`) — the tile is such a place.
    private static func editionCandidate(
        entry: LibraryEntry, series: Series, forthcoming: EditionAnswerStore.Forthcoming
    ) -> NextVolumeEntry {
        NextVolumeEntry(
            seriesID: entry.seriesId,
            title: series.displayTitle ?? "Untitled series",
            volumeLabel: forthcoming.volumeLabel,
            date: forthcoming.date,
            coverURL: Self.widgetCover(series.cover),
            sourceName: forthcoming.sourceName,
            sourceURL: forthcoming.sourceURL
        )
    }
}
