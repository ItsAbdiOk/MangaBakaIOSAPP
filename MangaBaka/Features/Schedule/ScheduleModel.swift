import Foundation

/// Backing state for the release schedule.
///
/// Everything here is an estimate. No source publishes real manga schedules, so
/// each date is inferred from how often a series has actually shipped, and the
/// screen has to keep saying so.
@MainActor
@Observable
final class ScheduleModel {
    /// A group of works on the screen, with an honest description of what it is.
    struct Group: Identifiable, Equatable {
        let id: String
        let title: String
        let blurb: String
        let works: [ScheduledWork]
        /// True for the late group, which the screen tints.
        let isOverdue: Bool

        var count: String { "\(works.count)" }
    }

    private(set) var snapshot = ScheduleSnapshot()
    private(set) var progress = ScheduleProgress()
    private(set) var isLoading = false
    /// Set once the first `load()` has actually returned. Gap 95: `isLoading`
    /// alone is false before `load()` is ever called (a freshly constructed
    /// model, or the instant before `.task { await model.load() }` starts on
    /// the main actor), and in that window the screen fell straight through
    /// to `firstRunCard` — "0 ESTIMATED OF 0 IN SCOPE" and a live Measure
    /// button, on every cold open, before anything had actually been asked.
    private(set) var hasLoadedOnce = false

    /// What the screen shows, decided in one place — `ScheduleView` switches
    /// on this rather than reasoning about `isLoading`/`libraryFailure`/
    /// `isEmpty` itself.
    enum ScreenState: Equatable {
        case loading
        /// Nothing to show at all: the library could not be read and there
        /// is no announced content to fall back on either. When announced
        /// works still exist despite `snapshot.libraryFailure`, this screen
        /// renders as `.list` instead — see `hasAnyContent` and gap 96.
        case failed(APIError)
        case empty
        case list
    }

    /// Announced dates or estimated works, either one. Decision (gap 96):
    /// `snapshot.libraryFailure` on its own used to blank the whole screen
    /// even when the announced section — built from a different read — had
    /// real content, silently dropping estimates a reader could still see
    /// were missing if the section above them were allowed to render.
    private var hasAnyContent: Bool { !announced.isEmpty || !snapshot.isEmpty }

    var screenState: ScreenState {
        guard hasLoadedOnce else { return .loading }
        // An announced-fetch failure (gap 97) always renders as `.list`, even
        // over an otherwise-empty scope, so `AnnouncedSection` gets the
        // chance to show its own inline failure rather than the whole screen
        // silently reading as "nothing to predict yet" or a blocking
        // failure that never names what actually failed.
        guard announcedFailure == nil else { return .list }
        if let libraryFailure = snapshot.libraryFailure, !hasAnyContent { return .failed(libraryFailure) }
        if !hasAnyContent { return .empty }
        return .list
    }

    /// Volumes with dates their publishers have announced, for series the
    /// reader actually has.
    ///
    /// The rest of this screen is inference. These are facts, and where a fact
    /// exists the inference gets out of the way — see `groups`.
    private(set) var announced: [UpcomingWork] = []
    /// The reader's own library, keyed by series id, so an announced row can
    /// open the actual series (gap 101) — `UpcomingWork` carries only an id,
    /// not the `Series` a detail page needs, and this is the library walk
    /// that already ran to narrow `announced` down to the reader's own ids in
    /// the first place, not a second fetch.
    private(set) var seriesByID: [Int: Series] = [:]
    /// Why fetching announced dates failed, when it did. Gap 97:
    /// `calendar.mine(seriesIDs:)` collapses a failure into the same empty
    /// list a genuinely quiet week produces, so a reader offline saw
    /// "nothing announced" — indistinguishable from the truth. Batch 3's
    /// `ReleaseCalendar.lastFailure` is read on the same actor hop right
    /// after `mine` returns, per that property's own doc comment.
    private(set) var announcedFailure: APIError?

    /// The series an announced row names, when it decoded with the library
    /// walk. Nil for an id `UpcomingWork` carries that this session's copy of
    /// the library does not have a `Series` for.
    func series(for seriesId: Int) -> Series? { seriesByID[seriesId] }

    private let service: ReleaseScheduleService
    private let calendar: ReleaseCalendar?
    /// The shared library walk. This used to page the library itself, which on
    /// a real account is 24.7 MB — for a set of ids.
    ///
    /// Named for the library rather than just `snapshot`, because this type
    /// already has one of those and it means something else entirely.
    private let librarySnapshot: LibrarySnapshot?
    private var pollTask: Task<Void, Never>?

    init(
        service: ReleaseScheduleService,
        calendar: ReleaseCalendar? = nil,
        snapshot: LibrarySnapshot? = nil
    ) {
        self.service = service
        self.calendar = calendar
        librarySnapshot = snapshot
    }

    /// Series with an announced date, so a guess about them can be suppressed.
    var announcedSeriesIDs: Set<Int> {
        Set(announced.compactMap(\.seriesId))
    }

    /// Nothing in scope: no account, or nothing being read is still publishing.
    /// Not "the library could not be read" — that is `libraryFailure`.
    var isEmpty: Bool { snapshot.inScope == 0 && snapshot.libraryFailure == nil && !isLoading }
    /// Why the scope is unknown, when it is. Shown in place of the empty state.
    var libraryFailure: APIError? { isLoading ? nil : snapshot.libraryFailure }
    var isMeasuring: Bool { progress.isRunning }
    var isStale: Bool { snapshot.stale > 0 }

    /// "49 estimated of 55 in scope".
    var scopeLine: String {
        "\(snapshot.dated.count) estimated of \(snapshot.inScope) in scope"
    }

    var measuredLine: String {
        guard let measuredAt = snapshot.measuredAt else {
            return snapshot.pending > 0
                ? "\(snapshot.pending) still to measure"
                : "Not measured yet"
        }
        let now = Date()
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        // Rows measured at different times are described by the oldest: the
        // schedule is as old as its oldest estimate. Opening one series page
        // six weeks after a build refreshes one row, and "Measured 1 minute
        // ago" over 54 six-week-old rows was the flattering number chosen over
        // the honest one the same loop had already counted as stale.
        if let oldest = snapshot.oldestMeasuredAt, measuredAt.timeIntervalSince(oldest) > 86_400 {
            let span = formatter.localizedString(for: oldest, relativeTo: now)
                .replacing("ago", with: "")
                .trimmingCharacters(in: .whitespaces)
            return "Measured over the last \(span)"
        }
        // "Measured 0 seconds ago" is what a relative formatter says the
        // instant a build lands, and "in 0 seconds" is what it says a moment
        // before that if the clocks disagree by a hair.
        let age = now.timeIntervalSince(measuredAt)
        guard age >= 60 else { return "Measured just now" }
        return "Measured \(formatter.localizedString(for: measuredAt, relativeTo: now))"
    }

    var remeasureLabel: String { snapshot.measuredAt == nil ? "Measure" : "Re-measure" }

    /// What went wrong the last time, when something did and it left series
    /// unmeasured. `ScheduleProgress.failure` was written by the build and
    /// read by nothing, so a measurement in which every request failed ended
    /// in silence with "55 still to measure" and no reason.
    var measurementFailureLine: String? {
        guard !isMeasuring, !isLoading, snapshot.pending > 0, let failure = progress.failure else {
            return nil
        }
        // The headline, not the full message: this is one line under a
        // card, and "MangaUpdates had a problem" says who and enough.
        return "\(snapshot.pending) not measured — \(failure.headline)."
    }

    /// Nothing has ever been measured, and nothing is being measured now.
    ///
    /// The first run showed a "Measure" button, a panel reading "0 ESTIMATED
    /// OF 0 IN SCOPE", and two thirds of an empty screen. "0 of 0" is not a
    /// number anyone can act on, and nothing said what pressing Measure would
    /// do or that it takes minutes.
    var hasNeverMeasured: Bool { snapshot.measuredAt == nil && !isMeasuring && !isLoading }

    /// Roughly how long a first measurement will take, in words.
    ///
    /// Derived, not guessed: MangaUpdates is asked for one series at a time
    /// and the client holds requests to one every
    /// `MangaUpdatesClient.minimumInterval` seconds, so the wait is the number
    /// of series in scope times that interval. Rounded up to whole minutes —
    /// "about 3 minutes" is honest where "2 minutes 47 seconds" pretends to a
    /// precision the network does not have.
    var firstRunEstimate: String {
        let seconds = Double(snapshot.inScope) * MangaUpdatesClient.minimumInterval
        guard seconds >= 60 else { return "under a minute" }
        let minutes = Int((seconds / 60).rounded(.up))
        return "about \(minutes) minute\(minutes == 1 ? "" : "s")"
    }

    /// What the first run is about to do, said plainly.
    ///
    /// L8: "three seconds apart" used to be a copied-out literal beside
    /// `firstRunEstimate`, which derives from
    /// `MangaUpdatesClient.minimumInterval` itself — a spacing change there
    /// (the other three feed clients already space at 3.5s) would leave this
    /// sentence saying the old number next to an estimate computed from the
    /// new one.
    var firstRunExplanation: String {
        let interval = MangaUpdatesClient.minimumInterval
        let spacing = interval.formatted(.number.precision(.fractionLength(0...1)))
        return """
        \(snapshot.inScope) series are in scope. MangaUpdates is asked about \
        one at a time, \(spacing) second\(interval == 1 ? "" : "s") apart, so \
        this takes \(firstRunEstimate). You can leave the screen — progress is kept.
        """
    }
    var measuringLine: String { "Reading \(progress.done) of \(progress.total)" }

    /// Groups, in the order the screen shows them.
    ///
    /// A reader opens this to find what is coming, so "due soon" leads — but
    /// late comes second and is not hidden. On a real library 61% of estimates
    /// were already in the past, some by years, so treating late as an
    /// exception would leave almost nothing on screen.
    var groups: [Group] {
        let now = Date()
        let horizon = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now

        var dueSoon: [ScheduledWork] = []
        var later: [ScheduledWork] = []
        var late: [ScheduledWork] = []

        // A series with an announced date is not guessed about. Showing both
        // would put "probably around the 12th" beside "the 15th" for the same
        // series, and the reader would have to work out which to believe.
        let announcedIDs = announcedSeriesIDs

        for work in snapshot.dated {
            guard let cadence = work.cadence else { continue }
            guard !announcedIDs.contains(work.series.id) else { continue }
            if cadence.state(asOf: now) == .late {
                late.append(work)
            } else if cadence.due <= horizon {
                dueSoon.append(work)
            } else {
                later.append(work)
            }
        }

        var groups: [Group] = []
        if !dueSoon.isEmpty {
            groups.append(Group(
                id: "due-soon",
                title: "Next 7 days",
                blurb: "Due within the week, if each keeps to its usual gap.",
                works: dueSoon,
                isOverdue: false
            ))
        }
        if !late.isEmpty {
            groups.append(Group(
                id: "late",
                title: "Past due",
                blurb: """
                Overdue against their own rhythm. Some stopped years ago — a \
                scanlation ending is not something the API reports.
                """,
                works: late,
                isOverdue: true
            ))
        }
        if !later.isEmpty {
            groups.append(Group(
                id: "later",
                title: "Later",
                blurb: "Further out than a week.",
                works: later,
                isOverdue: false
            ))
        }
        if !snapshot.undated.isEmpty {
            groups.append(Group(
                id: "undated",
                title: "Nothing due",
                blurb: "In scope, but with no honest date to give.",
                works: snapshot.undated,
                isOverdue: false
            ))
        }
        return groups
    }

    func load() async {
        isLoading = true
        snapshot = await service.snapshot()
        progress = await service.progress
        isLoading = false
        // Coming back to a build still running: follow it again. Leaving the
        // screen cancelled the poll and nothing restarted it, so the card
        // promising "leaving does not lose progress — it resumes" sat frozen
        // at whatever count it had when the reader left.
        if progress.isRunning { followBuild() }
        await loadAnnounced()
        hasLoadedOnce = true
    }

    /// Shown under the announced section when the library measurement failed
    /// but there is still announced content to show above it (gap 96) — the
    /// StaleBar names what is missing rather than the screen silently
    /// dropping the estimates section with no explanation.
    var announcedStaleLine: (headline: String, detail: String)? {
        guard let libraryFailure = snapshot.libraryFailure, !announced.isEmpty else { return nil }
        return ("Estimates couldn't be measured", libraryFailure.userFacingMessage)
    }

    /// Whether the screen is following a build. For the test that pins the
    /// resume above; nothing on screen reads it.
    var isFollowingBuild: Bool { pollTask != nil }

    /// The announced half, narrowed to the reader's own library.
    ///
    /// The unfiltered window is 246 works in a month and almost none of them
    /// are yours, so an unnarrowed list would be a catalogue rather than a
    /// schedule. Without a library there is nothing to narrow against and the
    /// section simply does not appear — better than showing a stranger's
    /// release calendar under the heading "yours".
    private func loadAnnounced() async {
        guard let calendar, let librarySnapshot else { return }
        let entries = await librarySnapshot.all()
        seriesByID = Dictionary(
            uniqueKeysWithValues: entries.compactMap { entry in entry.series.map { (entry.seriesId, $0) } }
        )
        announced = await calendar.mine(seriesIDs: Set(entries.map(\.seriesId)))
        announcedFailure = await calendar.lastFailure
    }

    /// Retries just the announced half, for `AnnouncedSection`'s own inline
    /// failure (gap 97) — a reader offline for the estimates but back online
    /// for the announced dates should not have to re-run the whole
    /// `load()` (which also re-reads `service.snapshot()`) to try again.
    func retryAnnounced() async {
        await loadAnnounced()
    }

    /// Starts a measurement and follows it.
    func measure(refresh: Bool = false) async {
        await service.build(refresh: refresh)
        followBuild()
    }

    private func followBuild() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            // Each series is banked as it lands, so the screen fills in rather
            // than waiting three minutes for a whole answer.
            while !Task.isCancelled {
                guard let self else { return }
                if await !self.refreshProgress() {
                    self.pollTask = nil
                    WidgetSnapshot.write(
                        dueThisWeek: WidgetSnapshot.dueThisWeekItems(dated: self.snapshot.dated)
                    )
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Returns whether a build is still running.
    private func refreshProgress() async -> Bool {
        progress = await service.progress
        snapshot = await service.snapshot()
        return progress.isRunning
    }

    /// Injects a snapshot so grouping can be tested without a network or a
    /// database. Grouping is the part with judgement in it.
    ///
    /// Also marks the model as having loaded once — every existing caller of
    /// this is simulating "the read already happened", and `screenState`
    /// treating an injected snapshot as still `.loading` would make gap 95's
    /// own tests unable to reach the states they are checking.
    func applyForTesting(_ snapshot: ScheduleSnapshot) {
        self.snapshot = snapshot
        isLoading = false
        hasLoadedOnce = true
    }

    func applyForTesting(_ progress: ScheduleProgress) {
        self.progress = progress
    }

    /// Injects announced works (and, optionally, an announced-fetch failure)
    /// directly, so gaps 96 and 97 can be tested without a real
    /// `ReleaseCalendar`/`LibrarySnapshot`.
    func setAnnouncedForTesting(_ works: [UpcomingWork], failure: APIError? = nil) {
        announced = works
        announcedFailure = failure
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }
}
