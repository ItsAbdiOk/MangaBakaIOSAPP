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
    ///     answer, not a failure: it just means conditions 1b/2b/2c never
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
        return confirmedReleases(announced: announced, now: now, notifiable: notifiable)
            + confirmedEpisodes(
                feeds: feeds, library: library, lastKnownEpisode: lastKnownEpisode,
                now: now, notifiable: notifiable
            )
            + completions(
                library: library, feeds: feeds, now: now,
                previousStatus: previousStatus, lastKnownSeason: lastKnownSeason
            )
    }

    /// (1a) A publisher-stated date, out today or earlier. Never a cadence
    /// guess — see the deleted `predicted` branch this replaces.
    /// - Parameter notifiable: series ids the reader is reading, rereading or
    ///   has paused. A release for anything else is not a reminder — see
    ///   `notifiableStates`. A work with no `seriesId` at all cannot be
    ///   checked and is dropped rather than guessed at.
    private static func confirmedReleases(
        announced: [UpcomingWork], now: Date, notifiable: Set<Int>
    ) -> [PlannedNotification] {
        let today = Calendar.current.startOfDay(for: now)
        return announced.compactMap { work -> PlannedNotification? in
            guard let seriesId = work.seriesId, notifiable.contains(seriesId) else { return nil }
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
        feeds: [Int: ReleaseFeed], library: [LibraryEntry], lastKnownEpisode: [Int: Int], now: Date,
        notifiable: Set<Int>
    ) -> [PlannedNotification] {
        feeds.compactMap { seriesID, feed -> PlannedNotification? in
            guard notifiable.contains(seriesID) else { return nil }
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

            // (2c) DELETED 2026-09-14, Abdi's call (Q3). It fired "<title> has
            // finished" from a feed's flag for the *Korean original*, on first
            // sight, with no baseline and worded identically to 2a's catalogue
            // completion — so a webtoon that ended in 2019 notified the day its
            // feed was first cached, and could say it two days running when
            // 2a's cooldown dropped 2c's first attempt. Whether it fired at all
            // depended on which provider's cache file happened to be on disk.
            // The catalogue status in 2a already covers the reader's ask, and
            // `TranslationGap.originalComplete` says the useful version of this
            // on the page — "the translation will catch up and stop" — rather
            // than "it has finished".
        }
        return planned
    }

    private static func title(for seriesID: Int, in library: [LibraryEntry], fallback: String?) -> String {
        library.first { $0.seriesId == seriesID }?.series?.displayTitle
            ?? fallback ?? "A series you follow"
    }
}
