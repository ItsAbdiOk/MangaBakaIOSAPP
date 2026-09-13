import Foundation

/// What is worth telling the reader about, and nothing else.
///
/// Abdi's rule (2026-09-13, verbatim intent): "We don't want to spam users
/// with notifications for predictions that are not important. Limit
/// notifications to: (1) release notifications for something that has just
/// come out, confirmed; (2) a series they're reading or have paused has
/// either completed or finished the end of a season. Those are the only
/// conditions. I get notification fatigue very quickly." Every other kind of
/// notification this app used to send — a cadence prediction, a monthly
/// backlog nudge, a "you have not opened this" nudge — is gone; see
/// `ReleaseReminders` for what was removed and why.
///
/// A pure function over what the app already knows, not a client of its own,
/// so the two conditions above can be tested directly against fixed inputs
/// rather than through `UNUserNotificationCenter` — see `NotificationPolicyTests`.
/// Dedup against what has already fired, the once-per-series-per-day fatigue
/// guard, and the 09:00 catch-up for anything past the daily cap are
/// `ReleaseReminders`' job, the same split `ReadingNudges`/`ReleaseReminders
/// .backToIt` used before this batch — this type only decides which facts are
/// worth saying at all.
enum NotificationPolicy {
    /// One condition this batch has found true, before dedup or pacing.
    struct PlannedNotification: Equatable, Sendable {
        let id: String
        /// nil only for a condition with no single series to attribute it to
        /// — none currently exist, but the fatigue guard groups by this, so
        /// a future case that lacks one degrades to "never rate-limited by
        /// series" rather than a crash.
        let seriesID: Int?
        let title: String
        let body: String
        let date: Date
    }

    /// Series states worth condition (2) — completed or season-ended. Reading
    /// and paused only: `.dropped` and `.planToRead` are states the reader
    /// already chose to stop caring about, and telling them a dropped series
    /// finished is not news, it is a series they walked away from.
    private static let trackedForCompletion: Set<LibraryEntry.State> = [.reading, .paused]

    /// - Parameters:
    ///   - announced: `UpcomingWork`s with a real, publisher-stated date —
    ///     never a `Cadence` prediction. `ReleaseReminders` used to also take
    ///     a `predicted: [ScheduledWork]` list here and turn a cadence guess
    ///     into "probably due" wording; that branch is deleted rather than
    ///     disabled, per Abdi's rule above.
    ///   - feeds: a release feed per series id, where the caller has one —
    ///     `ReleaseFeedService.report(for:)` costs a network round trip per
    ///     series, so this is only ever what was already fetched for some
    ///     other reason (a detail-screen visit). Empty is a legitimate
    ///     answer, not a failure: it just means conditions 1b/2b/2c never
    ///     fire until something else has warmed the cache. See
    ///     `RootView+Session.refreshReminders`, which currently passes `[:]`
    ///     — there is nowhere in that call path with a feed already in hand,
    ///     and this batch does not add a network call to make one.
    ///   - library: the reader's current library, for state and status.
    ///   - previousStatus: each series' status the last time this ran, by
    ///     series id — nil for a series never checked before. **A series
    ///     seen for the first time only records its status; it does not
    ///     notify**, the same rule `PublisherFollows.check` already uses for
    ///     its first-ever check of a follow. Without this, turning the
    ///     feature on (or adding a library entry that happens to already be
    ///     `completed`) would fire once for every such series already in the
    ///     library — a burst on day one, not the rare "it just finished"
    ///     Abdi asked for.
    ///   - lastKnownEpisode: the highest feed episode number seen for a
    ///     series the last time this ran. Same first-seen rule as
    ///     `previousStatus`, for the same reason: a feed with twenty existing
    ///     episodes should not read as twenty new ones the day it is first
    ///     fetched.
    ///   - lastKnownSeason: the highest `ReleaseFeed.endedSeason` seen for a
    ///     series the last time this ran. Same first-seen rule.
    static func decide(
        announced: [UpcomingWork],
        feeds: [Int: ReleaseFeed] = [:],
        library: [LibraryEntry],
        now: Date,
        previousStatus: [Int: String] = [:],
        lastKnownEpisode: [Int: Int] = [:],
        lastKnownSeason: [Int: Int] = [:]
    ) -> [PlannedNotification] {
        confirmedReleases(announced: announced, now: now)
            + confirmedEpisodes(feeds: feeds, library: library, lastKnownEpisode: lastKnownEpisode, now: now)
            + completions(
                library: library, feeds: feeds, now: now,
                previousStatus: previousStatus, lastKnownSeason: lastKnownSeason
            )
    }

    /// (1a) A publisher-stated date, out today or earlier. Never a cadence
    /// guess — see the deleted `predicted` branch this replaces.
    private static func confirmedReleases(announced: [UpcomingWork], now: Date) -> [PlannedNotification] {
        let today = Calendar.current.startOfDay(for: now)
        return announced.compactMap { work -> PlannedNotification? in
            guard let date = work.localDay(), date <= today else { return nil }
            let title = work.title ?? "A release you are waiting for"
            return PlannedNotification(
                id: "release-work-\(work.id)",
                seriesID: work.seriesId,
                title: title,
                // The date is a fact, so it is stated as one — no "probably",
                // no "roughly", the wording a prediction used to need.
                body: [work.volume, "out now"].compactMap { $0 }.joined(separator: " · "),
                date: date
            )
        }
    }

    /// (1b) A feed entry newer than the last one this app knew about for that
    /// series.
    private static func confirmedEpisodes(
        feeds: [Int: ReleaseFeed], library: [LibraryEntry], lastKnownEpisode: [Int: Int], now: Date
    ) -> [PlannedNotification] {
        feeds.compactMap { seriesID, feed -> PlannedNotification? in
            guard let episode = feed.latestEpisodeNumber else { return nil }
            guard let previous = lastKnownEpisode[seriesID] else { return nil } // first-seen: baseline only
            guard episode > previous else { return nil }
            let title = Self.title(for: seriesID, in: library, fallback: feed.title)
            return PlannedNotification(
                id: "release-feed-\(seriesID)-\(episode)",
                seriesID: seriesID,
                title: title,
                body: "Ep. \(episode) of \(title) is out",
                date: feed.lastEpisodeAt ?? now
            )
        }
    }

    /// (2) Completed or season-ended, reading or paused only.
    private static func completions(
        library: [LibraryEntry], feeds: [Int: ReleaseFeed], now: Date,
        previousStatus: [Int: String], lastKnownSeason: [Int: Int]
    ) -> [PlannedNotification] {
        var planned: [PlannedNotification] = []
        for entry in library where trackedForCompletion.contains(entry.state) {
            guard let series = entry.series else { continue }
            let seriesID = entry.seriesId
            let title = series.displayTitle ?? "A series you were reading"

            // (2a) The catalogue's own status flipped to completed.
            if let status = series.status, status == "completed",
               let previous = previousStatus[seriesID], previous != "completed" {
                planned.append(PlannedNotification(
                    id: "finished-\(seriesID)",
                    seriesID: seriesID,
                    title: "\(title) has finished",
                    body: "The series you were reading has completed.",
                    date: now
                ))
            }

            guard let feed = feeds[seriesID] else { continue }

            // (2b) A season ended, newer than the last one reported.
            if let season = feed.endedSeason, let endedOn = feed.lastEpisodeAt,
               let previousSeason = lastKnownSeason[seriesID], season > previousSeason {
                planned.append(PlannedNotification(
                    id: "season-\(seriesID)-\(season)",
                    seriesID: seriesID,
                    title: title,
                    body: "\(title): season \(season) has ended",
                    date: endedOn
                ))
            }

            // (2c) Naver's own completion flag, the first time it is seen.
            // Unlike 2a/2b, "first seen" fires rather than only recording a
            // baseline: Naver's `finished` is a fact stated once and never
            // retracted, and there is no earlier "not finished" reading of
            // it for this app to have missed — `TranslationGap`'s own
            // handling of this flag makes the same call.
            if feed.finished == true {
                planned.append(PlannedNotification(
                    id: "original-finished-\(seriesID)",
                    seriesID: seriesID,
                    title: title,
                    body: "\(title) has finished",
                    date: now
                ))
            }
        }
        return planned
    }

    private static func title(for seriesID: Int, in library: [LibraryEntry], fallback: String?) -> String {
        library.first { $0.seriesId == seriesID }?.series?.displayTitle
            ?? fallback ?? "A series you follow"
    }
}
