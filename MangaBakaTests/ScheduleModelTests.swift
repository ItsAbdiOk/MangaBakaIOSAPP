import Foundation
import Testing
@testable import MangaBaka

/// How the schedule groups what it has, which is where the honesty lives: on a
/// real library most estimates are already in the past.
@Suite("Schedule grouping")
@MainActor
struct ScheduleGroupingTests {
    private let calendar = Calendar(identifier: .gregorian)

    private func makeService() throws -> ReleaseScheduleService {
        ReleaseScheduleService(
            library: LibrarySnapshot(library: SilentLibrary()),
            mangaUpdates: MangaUpdatesClient(),
            database: try AppDatabase.inMemory()
        )
    }

    private final class SilentLibrary: LibraryProviding, @unchecked Sendable {
        func recommendationStatus() async throws(APIError) -> RecommendationStatus {
            throw APIError.offline
        }
        func recommendations(
            limit: Int, page: Int, excluding: [Int]
        ) async -> PersonalRecommendations { PersonalRecommendations() }
        func library(page: Int, limit: Int) async -> [LibraryEntry] { [] }
        func hiddenTagIDs() async -> Set<Int>? { [] }
        func topGenres() async -> [TopGenre]? { [] }
        func update(seriesId: Int, change: LibraryChange) async throws(APIError) {}
        func add(seriesId: Int, state: LibraryEntry.State) async throws(APIError) -> Bool { true }
        func remove(seriesId: Int) async throws(APIError) {}

    }

    private func cadence(dueIn days: Int, regular: Bool = true) -> Cadence {
        Cadence(
            medianGapDays: 7,
            spreadDays: regular ? 0 : 9,
            lastRelease: Date(),
            due: Date().addingTimeInterval(Double(days) * 86_400),
            samples: 20,
            gaps: 19,
            isRegular: regular
        )
    }

    private func work(_ id: Int, _ cadence: Cadence?, reason: ScheduledWork.Reason? = nil) -> ScheduledWork {
        ScheduledWork(
            series: SeriesFactory.make(id: id, title: "S\(id)"),
            cadence: cadence,
            reason: reason
        )
    }

    private func model(with snapshot: ScheduleSnapshot) throws -> ScheduleModel {
        let model = ScheduleModel(service: try makeService())
        model.applyForTesting(snapshot)
        return model
    }

    /// Screens F19 (2026-09-14): `.task { await model.load() }` re-ran on
    /// every pop-back, re-reading the library and replacing the snapshot.
    /// Injected rows stand in for a read that already happened: a second
    /// plain `load()` must leave them, a forced one must not. Expected to
    /// fail before the fix with: `model.snapshot.dated.count == 2` → `0`
    /// (the re-read replaced the injected snapshot with the empty service's).
    @Test("A re-appearance keeps the snapshot already on screen; a forced load reads again")
    func reappearanceDoesNotReread() async throws {
        var snapshot = ScheduleSnapshot()
        snapshot.dated = [work(1, cadence(dueIn: 1)), work(2, cadence(dueIn: 2))]
        let model = try model(with: snapshot)

        await model.load()
        #expect(model.snapshot.dated.count == 2)
        #expect(model.hasLoadedOnce)

        await model.load(forceRefresh: true)
        #expect(model.snapshot.dated.isEmpty, "The control: a forced load reads the (empty) service again")
    }

    @Test("Before the first measurement the screen says what it is about to do")
    func firstRunExplainsItself() throws {
        // The device showed "Not measured yet", a Measure button, and a panel
        // reading "0 ESTIMATED OF 0 IN SCOPE" over two thirds of an empty
        // screen. "0 of 0" is not a number a reader can act on, and nothing
        // said the measurement takes minutes.
        var snapshot = ScheduleSnapshot()
        snapshot.inScope = 55
        snapshot.measuredAt = nil
        let model = try model(with: snapshot)

        #expect(model.hasNeverMeasured)
        // 55 series, one MangaUpdates request every three seconds.
        #expect(model.firstRunEstimate == "about 3 minutes")
        #expect(model.firstRunExplanation.contains("55 series"))
        #expect(model.firstRunExplanation.contains("progress is kept"))

        // L8: the spacing named here used to be a copy of
        // `MangaUpdatesClient.minimumInterval` rather than a read of it, so a
        // spacing change there could leave this sentence naming the old
        // number beside an estimate computed from the new one.
        // Expected to fail before the fix with: the literal "three seconds"
        // never containing `minimumInterval`'s own formatted value, so a
        // change to the constant (e.g. 3.0 -> 3.5, matching the other feed
        // clients) would not move this assertion at all.
        let spacing = MangaUpdatesClient.minimumInterval.formatted(.number.precision(.fractionLength(0...1)))
        #expect(model.firstRunExplanation.contains("\(spacing) second"))
    }

    @Test("A measured schedule is past its first run")
    func measuredIsNotFirstRun() throws {
        var snapshot = ScheduleSnapshot()
        snapshot.inScope = 55
        snapshot.measuredAt = Date()
        #expect(try !model(with: snapshot).hasNeverMeasured)
    }

    @Test("A tiny library is not told to wait minutes")
    func shortEstimateReadsHonestly() throws {
        var snapshot = ScheduleSnapshot()
        snapshot.inScope = 4
        #expect(try model(with: snapshot).firstRunEstimate == "under a minute")
    }

    @Test("Due within a week, later, and past due are separated")
    func splitsByWhen() throws {
        var snapshot = ScheduleSnapshot()
        snapshot.dated = [
            work(1, cadence(dueIn: 2)),
            work(2, cadence(dueIn: 30)),
            work(3, cadence(dueIn: -400))
        ]
        snapshot.inScope = 3

        let groups = try model(with: snapshot).groups
        #expect(groups.map(\.id) == ["due-soon", "late", "later"])
        #expect(groups.first { $0.id == "late" }?.works.count == 1)
    }

    /// Past due is second, not hidden and not last. On a real library 61% of
    /// estimates were already in the past.
    @Test("Past due sits directly under what is coming")
    func lateIsProminent() throws {
        var snapshot = ScheduleSnapshot()
        snapshot.dated = [work(1, cadence(dueIn: -10)), work(2, cadence(dueIn: 3))]
        snapshot.inScope = 2

        let groups = try model(with: snapshot).groups
        #expect(groups.first?.id == "due-soon")
        #expect(groups.dropFirst().first?.id == "late")
        #expect(groups.first { $0.id == "late" }?.isOverdue == true)
    }

    /// Works with no date still appear, with the reason. Dropping them would
    /// hide them entirely, which is worse than saying nothing is known.
    @Test("Works with no estimate are shown with their reason")
    func undatedAreKept() throws {
        var snapshot = ScheduleSnapshot()
        snapshot.undated = [work(9, nil, reason: .onHiatus)]
        snapshot.inScope = 1

        let groups = try model(with: snapshot).groups
        let undated = try #require(groups.first { $0.id == "undated" })
        #expect(undated.works.first?.reason == .onHiatus)
        #expect(ScheduledWork.Reason.onHiatus.explanation == "On hiatus — estimate paused")
    }

    @Test("An empty scope reads as empty, not as an error")
    func emptyScope() throws {
        #expect(try model(with: ScheduleSnapshot()).isEmpty)
    }

    /// Offline, the library walk fails and nothing is in scope — which used to
    /// read as "0 in scope", the empty state, for a reader with 900 series.
    @Test("A library that could not be read is a failure, not an empty scope")
    func unreadableLibraryIsNotEmpty() throws {
        var snapshot = ScheduleSnapshot()
        snapshot.libraryFailure = .offline
        let model = try model(with: snapshot)
        #expect(!model.isEmpty)
        #expect(model.libraryFailure == .offline)
    }

    /// The build recorded its failure and no view read it: a measurement in
    /// which every request failed ended with "55 still to measure" and no why.
    @Test("A measurement that left series unmeasured says why")
    func measurementFailureIsSaid() throws {
        var snapshot = ScheduleSnapshot()
        snapshot.inScope = 55
        snapshot.pending = 55
        let model = try model(with: snapshot)
        model.applyForTesting(
            ScheduleProgress(isRunning: false, done: 55, total: 55, failure: .server(
                status: 503, message: "MangaUpdates returned 503.", party: .mangaUpdates
            ))
        )
        #expect(model.measurementFailureLine == "55 not measured — MangaUpdates had a problem.")
    }

    @Test("A finished measurement with nothing left says nothing")
    func completeMeasurementSaysNothing() throws {
        var snapshot = ScheduleSnapshot()
        snapshot.inScope = 55
        let model = try model(with: snapshot)
        model.applyForTesting(ScheduleProgress(isRunning: false, done: 55, total: 55, failure: nil))
        #expect(model.measurementFailureLine == nil)
    }

    /// Measure everything, come back six weeks later, open one series page:
    /// one row is fresh and 54 are old. The header used to report the fresh one.
    @Test("The measured line is as old as the oldest estimate")
    func measuredLineUsesOldest() throws {
        var snapshot = ScheduleSnapshot()
        snapshot.inScope = 55
        snapshot.measuredAt = Date().addingTimeInterval(-60)
        snapshot.oldestMeasuredAt = Date().addingTimeInterval(-42 * 86_400)
        let model = try model(with: snapshot)
        #expect(model.measuredLine == "Measured over the last 1 month")
    }

    @Test("Rows measured together report one time")
    func measuredLineForOneBuild() throws {
        var snapshot = ScheduleSnapshot()
        snapshot.inScope = 55
        snapshot.measuredAt = Date().addingTimeInterval(-3 * 3_600)
        snapshot.oldestMeasuredAt = Date().addingTimeInterval(-3 * 3_600 - 120)
        let model = try model(with: snapshot)
        #expect(model.measuredLine == "Measured 3 hours ago")
    }

    @Test("The scope line counts what was estimated against what is in scope")
    func scopeLine() throws {
        var snapshot = ScheduleSnapshot()
        snapshot.dated = [work(1, cadence(dueIn: 1)), work(2, cadence(dueIn: 2))]
        snapshot.inScope = 55
        #expect(try model(with: snapshot).scopeLine == "2 estimated of 55 in scope")
    }

    // MARK: - screenState (gap 95, 96)

    /// Gap 95: a freshly constructed model — the state a cold open is in for
    /// the instant before `.task { await model.load() }` actually starts —
    /// used to fall straight through to `firstRunCard`: "0 estimated of 0 in
    /// scope" and a live Measure button, over two thirds of an empty screen,
    /// before the first read had even been attempted.
    /// Expected to fail before the fix with: no `screenState` property
    /// existed on `ScheduleModel` at all.
    @Test("A model that has never loaded reads as loading, not empty")
    func freshModelIsLoading() throws {
        let model = ScheduleModel(service: try makeService())
        #expect(model.screenState == .loading)
    }

    @Test("A loaded, genuinely empty scope reads as empty")
    func loadedEmptyScopeIsEmpty() throws {
        #expect(try model(with: ScheduleSnapshot()).screenState == .empty)
    }

    /// The plain failure case: the library could not be read and there is
    /// nothing else — no announced content — to show instead.
    @Test("A library failure with nothing else to show is a failure screen")
    func libraryFailureWithNothingElseIsFailed() throws {
        var snapshot = ScheduleSnapshot()
        snapshot.libraryFailure = .offline
        guard case .failed(.offline) = try model(with: snapshot).screenState else {
            Issue.record("expected .failed(.offline)")
            return
        }
    }

    /// Gap 96: a library measurement failing must not blank a screen that
    /// still has real, separately-sourced announced content to show — the
    /// StaleBar names what is missing instead of the whole screen vanishing.
    /// Expected to fail before the fix with: `screenState == .failed`, and
    /// `announcedStaleLine == nil` since the property did not exist —
    /// the announced section this reader could still see was dropped along
    /// with the estimates that failed to measure.
    @Test("A library failure with announced content still to show renders as a list")
    func libraryFailureWithAnnouncedContentIsList() throws {
        var snapshot = ScheduleSnapshot()
        snapshot.libraryFailure = .offline
        let model = try model(with: snapshot)
        model.setAnnouncedForTesting([
            UpcomingWork(
                id: "w1", seriesId: 42, releaseDate: nil, sequenceString: "3",
                sequenceNumeric: nil, pages: nil, prices: nil, identifiers: nil,
                links: nil, collections: nil, countType: nil
            )
        ])
        #expect(model.screenState == .list)
        let stale = try #require(model.announcedStaleLine)
        #expect(stale.headline == "Estimates couldn't be measured")
    }

    /// Gap 97: `ReleaseCalendar.mine(seriesIDs:)` collapses a failure into
    /// the same empty list a genuinely quiet week produces —
    /// `announcedFailure` is how `ScheduleModel` still tells them apart, and
    /// `screenState` must not let an otherwise-empty scope hide it behind a
    /// whole-screen `.empty`/`.failed` that says nothing about the announced
    /// section specifically.
    /// Expected to fail before the fix with: `screenState == .empty` and
    /// `announcedFailure == nil` — no such property existed, and the section
    /// simply would not have appeared with no explanation.
    @Test("An announced-fetch failure still renders as a list, not the whole-screen empty state")
    func announcedFailureStillRendersAsList() throws {
        let model = try model(with: ScheduleSnapshot())
        model.setAnnouncedForTesting([], failure: .offline)
        #expect(model.screenState == .list)
        #expect(model.announcedFailure == .offline)
    }

    /// The measurement failure has to survive all the way to the first-run
    /// card, not just the scope card that only ever shows once something has
    /// been measured before.
    @Test("A first measurement that fails entirely says so on the first-run card's own state")
    func firstRunMeasurementFailureIsReported() throws {
        var snapshot = ScheduleSnapshot()
        snapshot.inScope = 55
        snapshot.pending = 55
        let model = try model(with: snapshot)
        model.applyForTesting(
            ScheduleProgress(isRunning: false, done: 0, total: 55, failure: .offline)
        )
        #expect(model.hasNeverMeasured, "measuredAt is still nil — nothing ever succeeded")
        #expect(model.measurementFailureLine == "55 not measured — You're offline.")
    }
}

/// `AnnouncedSection` opens the series a row names (gap 101) and never opens
/// a publisher link outside the ordinary web scheme allowlist.
@Suite("Announced link safety")
struct UpcomingWorkLinkTests {
    private func work(publisherLink raw: String?) throws -> UpcomingWork {
        let linksJSON = raw.map { #"[{"type":"publisher","link":"\#($0)"}]"# } ?? "null"
        return try Fixture.decoder().decode(UpcomingWork.self, from: Data("""
        {"id":"w1","links":\(linksJSON)}
        """.utf8))
    }

    /// Gap 101: this used to be a bare `URL(string:)` with no scheme check —
    /// the one contributed-data field on this type nothing else in the app
    /// guarded, unlike `SeriesLink.safeURL` and `NewsItem.safeURL`.
    /// Expected to fail before the fix with: a non-nil `URL` for
    /// "javascript:alert(1)", since `URL(string:)` accepts it happily.
    @Test("An unsafe scheme never becomes a publisher link")
    func unsafeSchemeIsRejected() throws {
        #expect(try work(publisherLink: "javascript:alert(1)").publisherLink == nil)
    }

    @Test("An ordinary web link is kept")
    func webLinkIsKept() throws {
        #expect(try work(publisherLink: "https://example.com/book").publisherLink != nil)
    }

    @Test("No publisher link at all is nil, not a crash")
    func noLinkIsNil() throws {
        #expect(try work(publisherLink: nil).publisherLink == nil)
    }
}
