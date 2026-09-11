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

    private static let key = "reminders.enabled"
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

    /// Drops every pending reminder without turning the feature off.
    ///
    /// For an account change. `disable()` is the reader saying they do not
    /// want reminders; this is the app saying the ones it has are about
    /// somebody else's library. Keeping `isEnabled` means the next refresh
    /// schedules the new account's releases rather than silently stopping.
    func cancelAll() async {
        await centre.removeAll()
    }

    /// Replaces every pending reminder with one per upcoming release.
    ///
    /// Replaces rather than adds: a release date moves, a series leaves the
    /// library, a reader changes their mind. Adding to what is already there
    /// accumulates notifications for things that are no longer true, and there
    /// is no way for the reader to tell which is which.
    ///
    /// - Parameter libraryFailure: why the library could not be read this
    ///   time, if it could not. Nothing is replaced then: a reminder set from
    ///   the library as it was yesterday is still right, and coming back to
    ///   the app offline used to wipe every one of them.
    func reschedule(
        announced: [UpcomingWork],
        predicted: [ScheduledWork],
        library: [LibraryEntry] = [],
        libraryFailure: APIError? = nil
    ) async {
        guard libraryFailure == nil else { return }
        await centre.removeAll()
        guard isEnabled else { return }

        var requests: [ReminderRequest] = []

        let now = now()
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
                id: id, now: now, previous: previous, after: 60 * 60 * 24, repeats: false
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
        let behind = ReadingInsights.waiting(in: entries, minimum: 10)
        if let biggest = behind.first,
           let date = nudgeDate(
               id: "catch-up", now: now, previous: previous, after: 60 * 60 * 24 * 30, repeats: true
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
