import Foundation
import UserNotifications

/// Telling the reader when something they are waiting for is due.
///
/// The Schedule screen has known this for a while and only ever said it to
/// someone already looking at it, which is the wrong way round: the whole point
/// of a release date is that you are not thinking about it yet.
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

    /// Whether the reader has separately asked for "back to it" nudges — off
    /// by default. An unrequested notification is a surprise, and this one
    /// is opinionated in a way an upcoming-release reminder is not: it is
    /// telling the reader they have not opened something, which the main
    /// switch's own reader might not want.
    private(set) var backToItEnabled: Bool
    /// Same reasoning as `effectiveEnabled`: what the reader asked for, only
    /// once iOS is actually willing to deliver it.
    var effectiveBackToItEnabled: Bool { backToItEnabled && systemStatus != .denied }

    private static let key = "reminders.enabled"
    private static let backToItKey = "reminders.backToIt.enabled"
    /// iOS keeps at most 64 pending local notifications per app and silently
    /// drops the rest, so the cap is picked rather than discovered: the nearest
    /// forty leaves room and covers further ahead than anyone plans.
    static let limit = 40

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
        backToItEnabled = defaults.bool(forKey: Self.backToItKey)
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

    /// Turns "back to it" nudges on or off. Independent of `enable()`/
    /// `isEnabled`: a reader can want the calendar reminders and not this,
    /// or the reverse. Still needs the same system permission, so turning it
    /// on for the first time asks for it exactly as `enable()` does.
    @discardableResult
    func setBackToIt(_ on: Bool) async -> Bool {
        guard on else {
            backToItEnabled = false
            defaults.set(false, forKey: Self.backToItKey)
            return true
        }
        let granted = await centre.requestAuthorization()
        await refreshStatus()
        guard granted else {
            backToItEnabled = false
            defaults.set(false, forKey: Self.backToItKey)
            return false
        }
        backToItEnabled = true
        defaults.set(true, forKey: Self.backToItKey)
        return true
    }

    /// One local notification, outside the replace-everything set
    /// `reschedule()` manages — a publisher follow's "new from X" fires the
    /// moment it is noticed rather than waiting for the next calendar
    /// rebuild, and must not be wiped by that rebuild's `removeAll()`.
    ///
    /// Gap, not fixed here: iOS's own 64-pending cap is shared with
    /// `reschedule()`'s 40, and nothing orders the two paths against each
    /// other — a reader who follows enough publishers and also has a full
    /// calendar could start losing whichever arrived first.
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
    /// **Does not clear `nudgeDates`.** Those are keyed by series id, not by
    /// account, so a `finished-<seriesId>` the previous account was already
    /// nudged about is treated as already-fired for the next account too, and
    /// the monthly catch-up nudge keeps ticking on the old account's clock.
    /// Call `forget()` instead of this on an actual account change; this stays
    /// for whatever else calls it expecting only the pending requests to go.
    func cancelAll() async {
        await centre.removeAll()
    }

    /// Everything this store remembers about who was signed in: pending
    /// reminders and when each nudge last fired. `cancelAll()` alone leaves
    /// `nudgeDates` behind — see its doc comment for what that breaks on an
    /// account change.
    func forget() async {
        await centre.removeAll()
        defaults.removeObject(forKey: Self.nudgeKey)
        defaults.removeObject(forKey: Self.backToItDatesKey)
    }

    /// Replaces every pending reminder with one per upcoming release.
    ///
    /// Replaces rather than adds: a release date moves, a series leaves the
    /// library, a reader changes their mind. Adding to what is already there
    /// accumulates notifications for things that are no longer true, and there
    /// is no way for the reader to tell which is which.
    ///
    /// - Parameters:
    ///   - libraryFailure: why the library could not be read this time, if it
    ///     could not. Nothing is replaced then: a reminder set from the
    ///     library as it was yesterday is still right, and coming back to the
    ///     app offline used to wipe every one of them.
    ///   - isComplete: whether the walk that produced `library` actually
    ///     finished. Gap 103: a walk that stopped at the page cap (or was cut
    ///     off some other way short of a hard failure) is not `libraryFailure`
    ///     — it succeeded, as far as this call knows — but it is still a
    ///     partial answer, and re-deriving reminders from it used to drop
    ///     every series past whatever page the walk reached, silently, on the
    ///     next reschedule. Treated the same as a failure for this call: keep
    ///     yesterday's reminders rather than removing ones for series this
    ///     walk simply never got to.
    ///   - lastOpened: for "back to it" nudges — when `HistoryStore` last saw
    ///     the reader open a series, by id. Only consulted when
    ///     `effectiveBackToItEnabled`; defaults to "never" for every id,
    ///     which just means every candidate falls back to its own
    ///     `startDate` (see `ReadingNudges.candidates`).
    ///   - latestKnownChapter: for "back to it" nudges — the newest chapter a
    ///     release feed already knows about for a series, ahead of what the
    ///     library's own `totalChapters` says. Defaults to nil for every id,
    ///     which falls back to `totalChapters` alone.
    ///   - readingHour: the hour of day, local time, to fire a "back to it"
    ///     nudge — the reader's own usual hour where `HistoryStore` can say,
    ///     else 19:00 (a guess: an evening hour, when someone with a job or
    ///     classes is plausibly free, chosen with no measurement behind it).
    func reschedule(
        announced: [UpcomingWork],
        predicted: [ScheduledWork],
        library: [LibraryEntry] = [],
        libraryFailure: APIError? = nil,
        isComplete: Bool = true,
        lastOpened: (Int) -> Date? = { _ in nil },
        latestKnownChapter: (Int) -> Double? = { _ in nil },
        readingHour: Int? = nil
    ) async {
        guard libraryFailure == nil, isComplete else { return }
        await centre.removeAll()
        // Each half of what this schedules is opted into separately — a
        // reader who wants the calendar but not "back to it" (or the
        // reverse) must not have their one choice silently gate the other.
        guard effectiveEnabled || effectiveBackToItEnabled else { return }

        var requests: [ReminderRequest] = []
        let now = now()

        if effectiveEnabled {
            let today = Calendar.current.startOfDay(for: now)
            for work in announced {
                // The release day in the reader's calendar, and today counts:
                // comparing the UTC instant against now dropped "out today" for
                // anyone once UTC midnight had passed.
                guard let date = work.localDay(), date >= today else { continue }
                requests.append(ReminderRequest(
                    id: "announced-\(work.id)",
                    title: work.title ?? "A release you are waiting for",
                    // The date is a fact, so it is stated as one.
                    body: [work.volume, "out today"].compactMap { $0 }.joined(separator: " · "),
                    date: date
                ))
            }

            for work in predicted {
                guard let cadence = work.cadence, cadence.due > now else { continue }
                requests.append(ReminderRequest(
                    id: "predicted-\(work.series.id)",
                    title: work.series.displayTitle ?? "A series you are reading",
                    // Worded as the estimate it is. A notification that states a
                    // guess as a fact is worse than no notification: it is the app
                    // being confidently wrong on the reader's lock screen.
                    body: "A new chapter is roughly due, going by how often it updates.",
                    date: cadence.due
                ))
            }

            let nudges = Self.catchUp(in: library, now: now, previous: nudgeDates)
            rememberNudges(nudges, now: now)
            requests.append(contentsOf: nudges)
        }

        if effectiveBackToItEnabled {
            let backToIt = Self.backToIt(
                in: library, now: now, lastOpened: lastOpened, latestKnownChapter: latestKnownChapter,
                previous: backToItDates, readingHour: readingHour ?? 19
            )
            rememberBackToIt(backToIt, now: now)
            requests.append(contentsOf: backToIt)
        }

        let soonest = requests
            .sorted { $0.date < $1.date }
            .prefix(Self.limit)
        for request in soonest {
            await centre.add(request)
        }
    }
}

extension ReleaseReminders {
    /// Two nudges about the library rather than about the calendar.
    ///
    /// These are the ones that solve the problem a tracker actually has. A
    /// release date tells you about one chapter of one series; these tell you
    /// about the reading you lost track of, which for most people is the larger
    /// pile by far.
    ///
    /// Deliberately not daily. A reminder that arrives every morning about the
    /// same forty-chapter backlog is a reminder you turn off — so the backlog
    /// one is monthly, and the finished one fires once per series because a
    /// series can only end once.
    ///
    /// - Parameter previous: when each nudge was last set to fire, by id. Every
    ///   reschedule used to set these at now+24h and now+30d afresh, so a reader
    ///   who opened the app daily never saw either — the date was always
    ///   tomorrow. A nudge keeps its date until it passes; then the finished
    ///   one is done (a series ends once) and the backlog one comes round again
    ///   a month later.
    static func catchUp(
        in entries: [LibraryEntry],
        now: Date = Date(),
        previous: [String: Date] = [:]
    ) -> [ReminderRequest] {
        var requests: [ReminderRequest] = []

        // It ended and nobody said. The worst way to lose a story: the last few
        // chapters are sitting there and you think you are up to date.
        for item in ReadingInsights.nearlyFinished(in: entries).prefix(3) {
            let id = "finished-\(item.entry.seriesId)"
            guard let date = nudgeDate(
                id: id, now: now, previous: previous,
                // A guess: no measurement behind "a day", just long enough
                // that this does not compete with whatever else notified the
                // reader today.
                after: 60 * 60 * 24, repeats: false
            ) else { continue }
            let title = item.series?.displayTitle ?? "A series you were reading"
            requests.append(ReminderRequest(
                id: id,
                title: "\(title) has finished",
                body: item.waiting == 1
                    ? "You are one chapter from the end."
                    : "You are \(item.waiting) chapters from the end.",
                date: date
            ))
        }

        // The backlog, once a month, and only when it is worth saying.
        //
        // A guess: ten chapters felt like "worth mentioning" against nothing
        // measured about how large a backlog has to be before it is a problem.
        let behind = ReadingInsights.waiting(in: entries, minimum: 10)
        if let biggest = behind.first,
           let date = nudgeDate(
               id: "catch-up", now: now, previous: previous,
               // A guess: a month, so the nudge is not frequent enough to be
               // the reminder that gets its notifications turned off.
               after: 60 * 60 * 24 * 30, repeats: true
           ) {
            let title = biggest.series?.displayTitle ?? "something you were reading"
            let others = behind.count - 1
            requests.append(ReminderRequest(
                id: "catch-up",
                title: "\(biggest.waiting) chapters of \(title) are waiting",
                body: others > 0
                    ? "And \(others) other series you were part way through."
                    : "Still where you left it.",
                date: date
            ))
        }

        return requests
    }

    /// "Back to it": at most `ReadingNudges.maxPerWeek` a week, spaced one a
    /// day, and never the same series again within `ReadingNudges.
    /// repeatBlock` of when it last fired — the same persisted-date trick
    /// `catchUp` uses for its own nudges, so a reader who opens the app daily
    /// does not get a nudge that keeps getting pushed back and never fires.
    ///
    /// - Parameter previous: when each candidate's nudge was last scheduled
    ///   to fire, by `"backtoit-<seriesID>"`. A candidate still waiting on a
    ///   future date keeps that date rather than being reassigned a new one
    ///   on every reschedule; a candidate whose date has passed is silent for
    ///   `ReadingNudges.repeatBlock` from when it fired, then eligible again.
    nonisolated static func backToIt(
        in entries: [LibraryEntry],
        now: Date,
        lastOpened: (Int) -> Date?,
        latestKnownChapter: (Int) -> Double? = { _ in nil },
        previous: [String: Date] = [:],
        readingHour: Int = 19,
        calendar: Calendar = .current
    ) -> [ReminderRequest] {
        let candidates = ReadingNudges.candidates(
            in: entries, now: now, lastOpened: lastOpened, latestKnownChapter: latestKnownChapter
        )

        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = readingHour
        components.minute = 0
        let todaySlot = calendar.date(from: components) ?? now
        // The first day any fresh candidate can land on — today's slot if
        // that has not passed yet, tomorrow's otherwise. Computed once, not
        // per candidate: doing it per candidate let two different candidates
        // both bump from an already-past "today" onto the same "tomorrow".
        let tomorrowSlot = calendar.date(byAdding: .day, value: 1, to: todaySlot) ?? todaySlot
        let anchor = todaySlot > now ? todaySlot : tomorrowSlot

        var requests: [ReminderRequest] = []
        var day = 0
        for candidate in candidates {
            guard requests.count < ReadingNudges.maxPerWeek else { break }
            let id = "backtoit-\(candidate.seriesID)"

            if let set = previous[id] {
                if set > now {
                    // Already scheduled and still ahead: kept, not
                    // reassigned, or a reader who opens the app daily would
                    // never see it move from "tomorrow".
                    requests.append(
                        ReminderRequest(id: id, title: candidate.title, body: candidate.line, date: set)
                    )
                    continue
                }
                guard now.timeIntervalSince(set) >= ReadingNudges.repeatBlock else { continue }
            }

            let date = calendar.date(byAdding: .day, value: day, to: anchor) ?? anchor
            requests.append(ReminderRequest(id: id, title: candidate.title, body: candidate.line, date: date))
            day += 1
        }
        return requests
    }

    private static let backToItDatesKey = "reminders.backToItDates"

    private var backToItDates: [String: Date] {
        (defaults.dictionary(forKey: Self.backToItDatesKey) as? [String: Date]) ?? [:]
    }

    private func rememberBackToIt(_ requests: [ReminderRequest], now: Date) {
        var dates = backToItDates
        for request in requests { dates[request.id] = request.date }
        defaults.set(dates, forKey: Self.backToItDatesKey)
    }

    /// When a nudge fires: its existing date while that is still ahead; a
    /// fresh one after `after` when there was none; nil once a one-off has
    /// passed.
    private static func nudgeDate(
        id: String, now: Date, previous: [String: Date], after: TimeInterval, repeats: Bool
    ) -> Date? {
        if let set = previous[id] {
            if set > now { return set }
            if !repeats { return nil }
        }
        return now.addingTimeInterval(after)
    }

    private static let nudgeKey = "reminders.nudgeDates"

    private var nudgeDates: [String: Date] {
        (defaults.dictionary(forKey: Self.nudgeKey) as? [String: Date]) ?? [:]
    }

    /// Keeps the fired one-offs on record too, so they are not re-set.
    private func rememberNudges(_ nudges: [ReminderRequest], now: Date) {
        var dates = nudgeDates
        for nudge in nudges { dates[nudge.id] = nudge.date }
        defaults.set(dates, forKey: Self.nudgeKey)
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
