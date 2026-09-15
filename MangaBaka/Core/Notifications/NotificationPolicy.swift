import Foundation

/// What is worth telling the reader about, and nothing else.
///
/// Abdi's rule (2026-09-15, verbatim): "NOTIFICATIONS ONLY FOR FINISHED OR
/// SEASON ENDING OR SERIES THAT HAVE JUST COME BACK FROM HIATUS." That
/// replaces the 2026-09-13 rule, which also allowed confirmed releases —
/// "(1) release notifications for something that has just come out" — and
/// it answers the deferral question those raised (how long a held-back
/// "Ep. 12 is out" stays worth sending): there are none to hold back now.
/// Conditions 1a (a publisher-dated volume out today) and 1b (a newer feed
/// episode) are deleted below, tombstoned where they stood. Everything else
/// this app used to send — a cadence prediction, a monthly backlog nudge, a
/// "you have not opened this" nudge — was already gone; see
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

    /// The states a reader is actually waiting on something in.
    ///
    /// Abdi, 2026-09-14 (Q1): notify for `reading`, `rereading` and `paused`
    /// only. `.dropped` and `.completed` are series they walked away from or
    /// finished, and `.planToRead` is discovery, not a reminder — "Vol. 12 ·
    /// out now" for a book they have not started is exactly the notification
    /// fatigue this whole file exists to prevent.
    ///
    /// Conditions 1a and 1b did not consult this until 2026-09-14 — they
    /// filtered by date alone, against this type's own "something they are
    /// waiting for" — so a dropped series' next print volume notified.
    static let notifiableStates: Set<LibraryEntry.State> = [.reading, .rereading, .paused]

    /// Condition (2) has always used the same set; the name is kept so the
    /// two conditions are visibly asking the same question.
    private static let trackedForCompletion: Set<LibraryEntry.State> = notifiableStates

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
    ///     answer, not a failure: it just means conditions 1b/2b never
    ///     fire until something else has warmed the cache.
    ///     `RootView+Session.refreshReminders` passes the cached feeds it
    ///     already has (it passed a literal `[:]` when this comment was first
    ///     written, which stopped being true and the comment did not).
    ///
    ///     **No background refresh** — Abdi, 2026-09-14 (Q2). A
    ///     `BGAppRefreshTask` over 55 series at `WebtoonsFeedClient`'s 3.5 s
    ///     spacing is ~3 minutes of a background slot and would contact three
    ///     publishers the app otherwise touches only when the reader opens
    ///     that page, which is a promise `WebtoonsFeedClient.swift:5-8` makes
    ///     in as many words. The consequence is accepted and must be said
    ///     honestly on screen instead: 1b reports the newest episode as of the
    ///     last time the reader opened that series, not as of today.
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
        let notifiable = Set(
            library.filter { notifiableStates.contains($0.state) }.map(\.seriesId)
        )
        // `announced` and `lastKnownEpisode` are still taken so the callers
        // and their tests read unchanged; nothing here reads them any more.
        _ = (announced, lastKnownEpisode, notifiable)
        return completions(
            library: library, feeds: feeds, now: now,
            previousStatus: previousStatus, lastKnownSeason: lastKnownSeason
        )
    }

    // (1a) DELETED 2026-09-15, Abdi's call: a publisher-dated volume out
    // today ("Vol. 12 · out now") no longer notifies. It read `announced`
    // against `notifiable` and `work.localDay() <= today`.
    //
    // (1b) DELETED 2026-09-15, same call: a feed episode newer than
    // `lastKnownEpisode` ("Ep. 12 of X is out") no longer notifies. The
    // baseline it kept is still recorded by `ReleaseReminders`, so restoring
    // either is the function back, not a data migration.

    /// (2) Completed, season-ended or back from hiatus — reading or paused only.
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

            // (2d) The catalogue's status left "hiatus" for anything that is
            // not a stop — "releasing" on MangaBaka; any status other than
            // completed/cancelled is read as a return, since the point is
            // "it is back", not which word the catalogue picked. Abdi,
            // 2026-09-15: "series that have just come back from hiatus".
            // Same baseline rule as 2a: a series first seen already back
            // says nothing.
            if let status = series.status, let previous = previousStatus[seriesID],
               previous == "hiatus", Self.isBack(status) {
                planned.append(PlannedNotification(
                    id: "back-\(seriesID)",
                    seriesID: seriesID,
                    title: "\(title) is back",
                    body: "The series you were reading has returned from hiatus.",
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

            // (2c) DELETED 2026-09-14, Abdi's call (Q3). It fired "<title> has
            // finished" from a feed's flag for the *Korean original*, on first
            // sight, with no baseline and worded identically to 2a's catalogue
            // completion — so a webtoon that ended in 2019 notified the day its
            // feed was first cached, and could say it two days running when
            // 2a's cooldown dropped 2c's first attempt. Whether it fired at all
            // depended on which provider's cache file happened to be on disk.
            // The catalogue status in 2a already covers the reader's ask. The
            // feed flag it read (`ReleaseFeed.finished`) was itself deleted on
            // 2026-09-14 — see the tombstone in `ReleaseFeedService.swift` —
            // so there is nothing left here to restore even if it were wanted.
        }
        return planned
    }

    /// A status that means the series is producing again. Not a fixed
    /// allow-list ("releasing") because the catalogue's vocabulary is
    /// `SeriesStatus.label`'s to keep and a new word for "ongoing" must not
    /// silently mute this; the two stops are the closed set.
    nonisolated static func isBack(_ status: String) -> Bool {
        !["hiatus", "completed", "cancelled", "canceled"].contains(status.lowercased())
    }

    private static func title(for seriesID: Int, in library: [LibraryEntry], fallback: String?) -> String {
        library.first { $0.seriesId == seriesID }?.series?.displayTitle
            ?? fallback ?? "A series you follow"
    }
}
