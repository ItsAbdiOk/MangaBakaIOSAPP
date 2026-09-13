import Foundation
import UserNotifications

/// Telling the reader when something they are waiting for is due.
///
/// The Schedule screen has known this for a while and only ever said it to
/// someone already looking at it, which is the wrong way round: the whole point
/// of a release date is that you are not thinking about it yet.
///
/// **Two conditions only, per Abdi (2026-09-13, verbatim intent):** "We don't
/// want to spam users with notifications for predictions that are not
/// important. Limit notifications to: (1) release notifications for something
/// that has just come out, confirmed; (2) a series they're reading or have
/// paused has either completed or finished the end of a season. Those are the
/// only conditions. I get notification fatigue very quickly." What counts as
/// either condition is `NotificationPolicy.decide`, a pure function tested on
/// its own; this type owns pacing (the daily cap, the same-series cooldown)
/// and the permission/persistence plumbing around it.
///
/// **Deleted, not disabled, per that rule:** cadence predictions ("probably
/// due"), the monthly backlog nudge, the "you have not opened this" nudge, and
/// the publisher-follow notification (the follow list itself stays; nothing
/// notifies from it yet). A cheaper fix would have been a settings switch left
/// off, but a switch someone can turn back on is still code that has to keep
/// working, and Abdi asked for these not to exist.
///
/// **Local notifications only.** Nothing is registered with a server, no device
/// token exists, and nothing about the reader's library leaves the phone. iOS
/// schedules these from data already on the device.
///
/// **Asked for, never assumed.** Permission is requested the moment the reader
/// switches the feature on in Settings and at no other time. A prompt on first
/// launch, before the app has shown it knows anything worth telling them, is
/// how an app gets denied permanently.
@MainActor
@Observable
final class ReleaseReminders {
    /// Whether the reader has asked for these at all. Separate from the system
    /// permission: someone can allow notifications and still turn this off.
    private(set) var isEnabled: Bool
    /// What iOS says, which the reader can change in Settings behind our back.
    private(set) var systemStatus: UNAuthorizationStatus = .notDetermined

    /// Gap 102: `isEnabled` alone reflects only what the reader asked this
    /// app for, not what iOS is actually willing to deliver — a reader who
    /// denies the system permission (or revokes it later in Settings) still
    /// saw the in-app switch reading On, with nothing scheduled and no way to
    /// tell why from the toggle itself. The view side of this (dimming the
    /// switch and offering Open Settings) is `RemindersSection`, batch 6.
    var effectiveEnabled: Bool { isEnabled && systemStatus != .denied }

    private static let key = "reminders.enabled"
    /// A guess: three a day. Enough that a reader with several confirmed
    /// releases or completions on the same day is not left wondering why
    /// nothing arrived, few enough that the lock screen never reads as spam
    /// — which is the entire complaint this batch exists to fix. Not
    /// measured against real usage; there was none to measure, since the
    /// feature that would have generated it (predictions, nudges) is what
    /// just got deleted.
    nonisolated static let dailyLimit = 3
    /// A guess: 24 hours. Two facts about the same series on the same day —
    /// a confirmed chapter and a season ending, say — read as the app
    /// repeating itself even though they are different facts; one is enough
    /// for one day.
    nonisolated static let sameSeriesCooldown: TimeInterval = 60 * 60 * 24

    private let defaults: UserDefaults
    private let centre: any NotificationScheduling
    private let now: () -> Date

    init(
        defaults: UserDefaults = .standard,
        centre: any NotificationScheduling = LiveNotificationCentre(),
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.centre = centre
        self.now = now
        isEnabled = defaults.bool(forKey: Self.key)
    }

    func refreshStatus() async {
        systemStatus = await centre.authorizationStatus()
    }

    /// Turns reminders on, asking iOS for permission if it has not been asked.
    ///
    /// Returns false when permission was refused, so the caller can leave the
    /// switch off rather than showing it on with nothing behind it.
    @discardableResult
    func enable() async -> Bool {
        let granted = await centre.requestAuthorization()
        await refreshStatus()
        guard granted else {
            isEnabled = false
            defaults.set(false, forKey: Self.key)
            return false
        }
        isEnabled = true
        defaults.set(true, forKey: Self.key)
        return true
    }

    func disable() async {
        isEnabled = false
        defaults.set(false, forKey: Self.key)
        await centre.removeAll()
    }

    /// One local notification, scheduled directly rather than through
    /// `reschedule()`'s dedup ledger — used for a condition that needs
    /// nothing beyond "has this exact id already fired".
    func notify(id: String, title: String, body: String, at date: Date = Date()) async {
        guard systemStatus != .denied else { return }
        await centre.add(ReminderRequest(id: id, title: title, body: body, date: date))
    }

    /// Drops every pending reminder without turning the feature off.
    ///
    /// For an account change. `disable()` is the reader saying they do not
    /// want reminders; this is the app saying the ones it has are about
    /// somebody else's library. Keeping `isEnabled` means the next refresh
    /// schedules the new account's releases rather than silently stopping.
    ///
    /// **Does not clear the dedup ledger.** That is keyed by series id, not by
    /// account, so a `finished-<seriesId>` the previous account was already
    /// told about is treated as already-fired for the next account too. Call
    /// `forget()` instead of this on an actual account change; this stays for
    /// whatever else calls it expecting only the pending requests to go.
    func cancelAll() async {
        await centre.removeAll()
    }

    /// Everything this store remembers about who was signed in: pending
    /// reminders, what has already fired, and the last status/episode/season
    /// observed per series. `cancelAll()` alone leaves that memory behind —
    /// see its doc comment for what that breaks on an account change.
    func forget() async {
        await centre.removeAll()
        defaults.removeObject(forKey: Self.firedKey)
        defaults.removeObject(forKey: Self.seriesLastNotifiedKey)
        defaults.removeObject(forKey: Self.statusKey)
        defaults.removeObject(forKey: Self.episodeKey)
        defaults.removeObject(forKey: Self.seasonKey)
    }

    /// Notifies about whatever `NotificationPolicy.decide` says is newly
    /// true, subject to the daily cap and the same-series cooldown.
    ///
    /// Unlike the calendar this used to rebuild, nothing here is
    /// replace-and-resend: a confirmed release or a completed series is a
    /// fact that does not move once it is true, so each one is scheduled
    /// once, through `notify()`, and left alone — `removeAll()` is never
    /// called here. The old rebuild-everything shape existed to correct a
    /// *predicted* date that could shift; there is no prediction left to
    /// correct.
    ///
    /// - Parameters:
    ///   - libraryFailure: why the library could not be read this time, if it
    ///     could not. Nothing is scheduled then — a fresh `library` read as
    ///     empty must not read as "nothing is reading or paused".
    ///   - isComplete: whether the walk that produced `library` actually
    ///     finished. A walk cut short at the page cap is not a fresh answer
    ///     either; see `libraryFailure`.
    func reschedule(
        announced: [UpcomingWork],
        library: [LibraryEntry] = [],
        feeds: [Int: ReleaseFeed] = [:],
        libraryFailure: APIError? = nil,
        isComplete: Bool = true
    ) async {
        guard libraryFailure == nil, isComplete else { return }
        guard effectiveEnabled else { return }

        let now = now()
        let candidates = NotificationPolicy.decide(
            announced: announced, feeds: feeds, library: library, now: now,
            previousStatus: seriesStatus, lastKnownEpisode: knownEpisode, lastKnownSeason: knownSeason
        )

        // A series/feed never observed before gets its baseline recorded
        // right away — a first sighting is never itself news, per
        // `NotificationPolicy`'s first-seen rule. An *existing* baseline is
        // deliberately left alone here: it only advances below, once a
        // candidate it would otherwise block has actually been sent. Moving
        // it eagerly would erase a flip the fatigue guard held back — the
        // next `reschedule` would see "no change" and the reader would never
        // be told at all.
        seedFirstSeenBaselines(library: library, feeds: feeds)

        let scheduled = Self.applyFatigueGuard(
            candidates, now: now, fired: fired, seriesLastNotified: seriesLastNotified
        )

        var updatedFired = fired
        var updatedSeriesLastNotified = seriesLastNotified
        var updatedStatus = seriesStatus
        var updatedEpisode = knownEpisode
        var updatedSeason = knownSeason
        for item in scheduled {
            await notify(id: item.id, title: item.title, body: item.body, at: item.date)
            updatedFired[item.id] = item.date
            guard let seriesID = item.seriesID else { continue }
            updatedSeriesLastNotified[seriesID] = now
            if item.id.hasPrefix("finished-"), let status = library.first(where: { $0.seriesId == seriesID })?
                .series?.status {
                updatedStatus[seriesID] = status
            } else if item.id.hasPrefix("release-feed-"), let episode = feeds[seriesID]?.latestEpisodeNumber {
                updatedEpisode[seriesID] = episode
            } else if item.id.hasPrefix("season-"), let season = feeds[seriesID]?.endedSeason {
                updatedSeason[seriesID] = season
            }
        }
        defaults.set(updatedFired, forKey: Self.firedKey)
        defaults.set(Self.encodeIntKeys(updatedSeriesLastNotified), forKey: Self.seriesLastNotifiedKey)
        defaults.set(Self.encodeIntKeys(updatedStatus), forKey: Self.statusKey)
        defaults.set(Self.encodeIntKeys(updatedEpisode), forKey: Self.episodeKey)
        defaults.set(Self.encodeIntKeys(updatedSeason), forKey: Self.seasonKey)
    }
}

extension ReleaseReminders {
    /// Applies the daily cap and the same-series cooldown to whatever
    /// `NotificationPolicy` found true this pass.
    ///
    /// A candidate already fired — `fired[id]` at or before `now` — is
    /// dropped outright: `PlannedNotification.id` embeds the specific episode
    /// or season number where one exists, so a *repeat* of the same episode
    /// cannot reach here, only the same id twice for the same event, which
    /// this refuses. Ordered soonest-date first so a same-day pile of
    /// candidates fills the day's three slots with the earliest facts, not
    /// an arbitrary one.
    ///
    /// - Parameter fired: id → the date each past notification was sent,
    ///   persisted so a relaunch does not forget what already went out.
    /// - Parameter seriesLastNotified: series id → the last time *any*
    ///   notification was sent about it, for the 24-hour same-series guard —
    ///   kept apart from `fired` because that is keyed by event id, not
    ///   series, and two different events (a chapter, then a season ending)
    ///   can share a series on the same day.
    nonisolated static func applyFatigueGuard(
        _ candidates: [NotificationPolicy.PlannedNotification],
        now: Date,
        fired: [String: Date],
        seriesLastNotified: [Int: Date],
        calendar: Calendar = .current
    ) -> [NotificationPolicy.PlannedNotification] {
        let tomorrowNine: Date = {
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.day = (components.day ?? 0) + 1
            components.hour = 9
            components.minute = 0
            return calendar.date(from: components) ?? now.addingTimeInterval(60 * 60 * 24)
        }()

        var results: [NotificationPolicy.PlannedNotification] = []
        var seriesSeenThisPass: [Int: Date] = seriesLastNotified
        var sentToday = 0

        for candidate in candidates.sorted(by: { $0.date < $1.date }) {
            guard fired[candidate.id] == nil else { continue }
            if let seriesID = candidate.seriesID, let last = seriesSeenThisPass[seriesID],
               now.timeIntervalSince(last) < ReleaseReminders.sameSeriesCooldown {
                continue
            }

            if sentToday < ReleaseReminders.dailyLimit {
                results.append(candidate)
                sentToday += 1
            } else {
                // The 4th+ of the day waits for tomorrow morning rather than
                // being dropped — a confirmed release or a finished series is
                // still worth saying, just not today.
                results.append(NotificationPolicy.PlannedNotification(
                    id: candidate.id, seriesID: candidate.seriesID,
                    title: candidate.title, body: candidate.body, date: tomorrowNine
                ))
            }
            if let seriesID = candidate.seriesID { seriesSeenThisPass[seriesID] = now }
        }
        return results
    }

    private static let firedKey = "reminders.fired"
    private static let seriesLastNotifiedKey = "reminders.seriesLastNotified"
    private static let statusKey = "reminders.seriesStatus"
    private static let episodeKey = "reminders.knownEpisode"
    private static let seasonKey = "reminders.knownSeason"

    private var fired: [String: Date] {
        (defaults.dictionary(forKey: Self.firedKey) as? [String: Date]) ?? [:]
    }

    private var seriesLastNotified: [Int: Date] {
        (defaults.dictionary(forKey: Self.seriesLastNotifiedKey) as? [String: Date])
            .map(Self.decodeIntKeys) ?? [:]
    }

    private var seriesStatus: [Int: String] {
        (defaults.dictionary(forKey: Self.statusKey) as? [String: String])
            .map(Self.decodeIntKeys) ?? [:]
    }

    private var knownEpisode: [Int: Int] {
        (defaults.dictionary(forKey: Self.episodeKey) as? [String: Int])
            .map(Self.decodeIntKeys) ?? [:]
    }

    private var knownSeason: [Int: Int] {
        (defaults.dictionary(forKey: Self.seasonKey) as? [String: Int])
            .map(Self.decodeIntKeys) ?? [:]
    }

    /// Fills in a baseline for anything with none yet — a series or feed this
    /// store has never checked before. Never overwrites an existing baseline:
    /// that only moves in `reschedule`, and only once whatever it would have
    /// unblocked has actually been sent.
    private func seedFirstSeenBaselines(library: [LibraryEntry], feeds: [Int: ReleaseFeed]) {
        var statuses = seriesStatus
        for entry in library where statuses[entry.seriesId] == nil {
            if let status = entry.series?.status { statuses[entry.seriesId] = status }
        }
        defaults.set(Self.encodeIntKeys(statuses), forKey: Self.statusKey)

        var episodes = knownEpisode
        var seasons = knownSeason
        for (seriesID, feed) in feeds {
            if episodes[seriesID] == nil, let episode = feed.latestEpisodeNumber {
                episodes[seriesID] = episode
            }
            if seasons[seriesID] == nil, let season = feed.endedSeason {
                seasons[seriesID] = season
            }
        }
        defaults.set(Self.encodeIntKeys(episodes), forKey: Self.episodeKey)
        defaults.set(Self.encodeIntKeys(seasons), forKey: Self.seasonKey)
    }

    /// `UserDefaults` dictionaries are string-keyed; every per-series map
    /// here is keyed by `Int` at the call site, so the two directions of this
    /// conversion live in one place instead of being re-derived per property.
    private static func encodeIntKeys<Value>(_ dict: [Int: Value]) -> [String: Value] {
        Dictionary(uniqueKeysWithValues: dict.map { (String($0.key), $0.value) })
    }

    private static func decodeIntKeys<Value>(_ dict: [String: Value]) -> [Int: Value] {
        Dictionary(uniqueKeysWithValues: dict.compactMap { key, value in
            Int(key).map { ($0, value) }
        })
    }
}

/// One reminder, before it becomes an iOS request.
struct ReminderRequest: Equatable, Sendable {
    let id: String
    let title: String
    let body: String
    let date: Date

    /// When it actually goes off.
    ///
    /// Nine in the morning, local time, on the day: a release that fires at
    /// midnight is a notification nobody sees and a phone that lit up in a dark
    /// room. But a trigger already in the past is refused by iOS, and the
    /// refusal was hidden behind `try?` — a chapter due at three this afternoon
    /// was scheduled for nine this morning and never arrived. So: nine if that
    /// is still ahead; the date itself if that is; a minute from now otherwise.
    static func triggerDate(for date: Date, now: Date, calendar: Calendar = .current) -> Date {
        var nine = calendar.dateComponents([.year, .month, .day], from: date)
        nine.hour = 9
        nine.minute = 0
        if let morning = calendar.date(from: nine), morning > now { return morning }
        if date > now { return date }
        return now.addingTimeInterval(60)
    }
}

/// The part of `UNUserNotificationCenter` this app uses.
///
/// A protocol so the scheduling rules can be tested without a notification
/// centre, which a unit test cannot have.
protocol NotificationScheduling: Sendable {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async -> Bool
    func add(_ request: ReminderRequest) async
    func removeAll() async
}

struct LiveNotificationCentre: NotificationScheduling {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorization() async -> Bool {
        // Alerts and sounds, not badges: a number on the icon that nobody
        // clears is a permanent accusation, and this app has nothing to count.
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func add(_ request: ReminderRequest) async {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: ReminderRequest.triggerDate(for: request.date, now: Date())
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: request.id, content: content, trigger: trigger)
        )
    }

    func removeAll() async {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}
