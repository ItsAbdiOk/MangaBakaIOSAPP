import AppIntents
import Foundation

/// "Open <series> in MangaBaka."
struct OpenSeriesIntent: AppIntent {
    static let title: LocalizedStringResource = "Open a series"
    static let description = IntentDescription("Opens a series from your library.")
    static let openAppWhenRun = true

    @Parameter(title: "Series")
    var series: LibrarySeriesEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$series)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentBridge.shared.pendingSeriesID = series.id
        return .result()
    }
}

/// "What's due this week in MangaBaka?"
struct DueThisWeekIntent: AppIntent {
    static let title: LocalizedStringResource = "What's due this week"
    static let description = IntentDescription(
        "Which of your series have a chapter or a volume due in the next seven days."
    )

    // `maxFeedFetches = 8` used to live here, capping how many release-feed
    // *fetches* one Siri question could make. Deleted 2026-09-14 with Abdi's
    // Q12 answer: the answer is now built from cache only, so there is no
    // fetch to cap. Eight fetches was never a workable cap anyway — each one
    // serialises behind its client's 3.5 s spacing, with a placeholder lookup
    // in front of most Webtoons links, so eight candidates was up to 56
    // seconds and Siri gives up long before that while the requests carry on
    // spending the publishers' budget on an answer nobody hears.

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let services = IntentBridge.shared.services else {
            return .result(dialog: "Open MangaBaka first, then ask again.")
        }
        let snapshot = await services.schedule.snapshot()
        let announced = await services.calendar.mine(seriesIDs: await services.librarySnapshot.seriesIDs())
        let feedWorks = await Self.feedDueWorks(
            for: snapshot.dated, feeds: services.releaseFeeds, repository: services.repository
        )
        let answer = DueThisWeek.sentence(
            dated: snapshot.dated,
            announced: announced,
            feedWorks: feedWorks,
            measured: snapshot.measuredAt != nil,
            now: Date(),
            libraryFailure: snapshot.libraryFailure
        )
        return .result(dialog: "\(answer)")
    }

    /// Real publisher dates for whichever scoped series already have a
    /// release feed cached, in place of the MangaUpdates-estimated cadence
    /// `snapshot.dated` otherwise falls back to for them.
    ///
    /// **Cache only** — `cachedReport`, never `report`; see that function and
    /// Abdi's Q12. Nothing here makes a request, so this is safe to call from
    /// a Siri answer and from the widget's snapshot build alike. A series
    /// whose feed has never been fetched (never opened) simply keeps its
    /// estimate, which is what the widget shows for it anyway.
    static func feedDueWorks(
        for works: [ScheduledWork],
        feeds: ReleaseFeedService,
        repository: any SeriesRepositoryProtocol
    ) async -> [DueThisWeek.FeedDueWork] {
        var candidates: [(series: Series, links: [SeriesLink])] = []
        for work in works {
            guard let extras = await repository.cachedExtras(for: work.series.id) else { continue }
            let hasFeedLink = extras.links.contains { ReleaseSource.serving($0.safeURL) != nil }
            guard hasFeedLink else { continue }
            candidates.append((work.series, extras.links))
        }
        guard !candidates.isEmpty else { return [] }

        return await withTaskGroup(of: DueThisWeek.FeedDueWork?.self) { group in
            for candidate in candidates {
                group.addTask {
                    let report = await feeds.cachedReport(for: candidate.series, links: candidate.links)
                    guard case let .rhythm(cadence, _) = report.summary else { return nil }
                    let sourceName = report.sourceName ?? report.source?.displayName ?? "the feed"
                    return DueThisWeek.FeedDueWork(
                        seriesId: candidate.series.id,
                        title: candidate.series.displayTitle ?? "Untitled series",
                        due: cadence.due,
                        sourceName: sourceName,
                        coverURL: candidate.series.cover.x250 ?? candidate.series.cover.x350
                    )
                }
            }
            var results: [DueThisWeek.FeedDueWork] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }
    }
}

/// The sentence, kept out of the intent so it can be tested.
enum DueThisWeek {
    static let window = 7

    /// A real next-release date from a publisher's own feed
    /// (`ReleaseFeedService`), standing in for the MangaUpdates-estimated
    /// cadence `ScheduledWork` otherwise carries for the same series.
    struct FeedDueWork: Sendable {
        let seriesId: Int
        let title: String
        let due: Date
        /// e.g. "Webtoons", or a GigaViewer host's own name — see
        /// `ReleaseReport.sourceName`.
        let sourceName: String
        /// Carried so the widget's row is not grey. `x250`/`x350` only, never
        /// `raw` — see `WidgetSnapshot.widgetCover`. Defaulted, because
        /// `DueThisWeek.sentence` never needed it and its tests build these
        /// by hand.
        var coverURL: URL?
    }

    /// Announced volumes first — they are facts — then feed-sourced real
    /// dates, then MangaUpdates estimates, soonest within each group. Late
    /// estimates are due too: a chapter three days overdue is still the one
    /// the reader is waiting for.
    static func sentence(
        dated: [ScheduledWork],
        announced: [UpcomingWork],
        feedWorks: [FeedDueWork] = [],
        measured: Bool,
        now: Date,
        calendar: Calendar = .current,
        /// Gap 105: this used to have no way to hear that the library read
        /// had failed, so "I don't know" (offline, rate-limited, whatever it
        /// was) came out of Siri's mouth as the same "Nothing due" a reader
        /// with a genuinely quiet week would hear — the one answer that is
        /// actually wrong to give with no library to check.
        libraryFailure: APIError? = nil
    ) -> String {
        if let libraryFailure, dated.isEmpty, announced.isEmpty, feedWorks.isEmpty {
            return "I couldn't read your library. \(libraryFailure.userFacingMessage)"
        }
        let today = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: window, to: today) else { return "" }

        var lines: [String] = []
        var seen: Set<Int> = []
        for work in announced {
            guard let day = work.localDay(calendar: calendar), day >= today, day < end,
                  let title = work.title, let id = work.seriesId, seen.insert(id).inserted
            else { continue }
            let volume = work.sequenceString.map { "volume \($0)" } ?? "a volume"
            lines.append("\(title), \(volume), \(when(day, today: today, calendar: calendar))")
        }

        let dueFeedWorks = feedWorks.filter {
            calendar.startOfDay(for: $0.due) < end && !seen.contains($0.seriesId)
        }
        let dueEstimates = dated.filter { work in
            guard let cadence = work.cadence else { return false }
            return calendar.startOfDay(for: cadence.due) < end && !seen.contains(work.series.id)
        }
        // Each cadence line only says which kind it is when both a real feed
        // date and a MangaUpdates estimate are due the same week — with only
        // one kind present the sentence reads exactly as it did before feeds
        // existed here.
        let mixed = !dueFeedWorks.isEmpty && !dueEstimates.isEmpty

        for work in dueFeedWorks {
            guard seen.insert(work.seriesId).inserted else { continue }
            let day = calendar.startOfDay(for: work.due)
            let suffix = mixed ? " (real dates from \(work.sourceName))" : ""
            lines.append("\(work.title), \(when(day, today: today, calendar: calendar))\(suffix)")
        }
        for work in dueEstimates {
            guard let cadence = work.cadence, seen.insert(work.series.id).inserted else { continue }
            let day = calendar.startOfDay(for: cadence.due)
            let title = work.series.displayTitle ?? "Untitled series"
            let suffix = mixed ? " (estimated)" : ""
            lines.append("\(title), \(when(day, today: today, calendar: calendar))\(suffix)")
        }

        if lines.isEmpty {
            return measured || !announced.isEmpty
                ? "Nothing due in the next \(window) days."
                : "The schedule hasn't been measured yet. Open MangaBaka to build it."
        }
        let head = lines.count == 1 ? "One thing due this week: " : "\(lines.count) due this week: "
        return head + lines.joined(separator: "; ") + "."
    }

    private static func when(_ day: Date, today: Date, calendar: Calendar) -> String {
        let days = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        return switch days {
        case ..<0: "\(-days) day\(days == -1 ? "" : "s") overdue"
        case 0: "today"
        case 1: "tomorrow"
        default: day.formatted(.dateTime.weekday(.wide))
        }
    }
}

struct MangaBakaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DueThisWeekIntent(),
            phrases: [
                "What's due this week in \(.applicationName)",
                "What's due in \(.applicationName)"
            ],
            shortTitle: "Due this week",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: OpenSeriesIntent(),
            phrases: ["Open a series in \(.applicationName)"],
            shortTitle: "Open a series",
            systemImageName: "book"
        )
    }
}
