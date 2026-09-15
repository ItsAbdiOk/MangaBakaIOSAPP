import Foundation
import GRDB
import os

/// A work in the schedule, with its estimate if it has one.
struct ScheduledWork: Identifiable, Equatable, Sendable {
    let series: Series
    let cadence: Cadence?
    /// Why there is no estimate, when there is none.
    let reason: Reason?

    var id: Int { series.id }

    enum Reason: String, Equatable, Sendable {
        case onHiatus
        case notOnMangaUpdates
        case tooFewReleases

        /// Shown to the reader. Says what happened rather than apologising.
        var explanation: String {
            switch self {
            case .onHiatus: "On hiatus — estimate paused"
            case .notOnMangaUpdates: "Not on MangaUpdates"
            case .tooFewReleases: "Too few dated releases to estimate from"
            }
        }
    }
}

/// Everything estimated so far. Never blocks on a build.
struct ScheduleSnapshot: Equatable, Sendable {
    /// Works with a date, soonest first.
    var dated: [ScheduledWork] = []
    /// Works in scope that will not get a date, and why.
    var undated: [ScheduledWork] = []
    /// In scope but not yet asked about.
    var pending: Int = 0
    /// Estimated, but from release history old enough to have missed one.
    var stale: Int = 0
    var inScope: Int = 0
    /// Why the library could not be read, when it could not. `inScope` is 0
    /// then, and must not be shown as "nothing in scope".
    var libraryFailure: APIError?
    /// When the newest estimate landed. Drives "has anything been measured".
    var measuredAt: Date?
    /// When the oldest still-used estimate landed. The header's age is taken
    /// from this: a schedule is as old as its oldest row, and reporting the
    /// newest one said "Measured 1 minute ago" over 54 rows six weeks old.
    var oldestMeasuredAt: Date?

    var isEmpty: Bool { dated.isEmpty && undated.isEmpty }
}

/// Progress of a background build.
struct ScheduleProgress: Equatable, Sendable {
    var isRunning = false
    var done = 0
    var total = 0
    /// The real `APIError`, not a flattened string (gap 98) — kept so a
    /// caller can tell MangaUpdates' own outage apart from MangaBaka's
    /// (`APIError.party`), and so `.server`'s message goes through
    /// `userFacingMessage` rather than being trapped in a `String` that
    /// already lost that distinction. Before this, every failure read as
    /// "MangaBaka had a problem" even when it was MangaUpdates that answered
    /// 503 (gap 100), because the party was dropped when the message was
    /// pre-rendered into a `String` here.
    var failure: APIError?

    var fraction: Double {
        total > 0 ? Double(done) / Double(total) : 0
    }
}

/// Estimates when the next chapter of each series you are reading is due.
///
/// **Deliberately narrow scope.** Only series that are being read *and* still
/// publishing *and* carry a MangaUpdates id. On the reference library that is
/// 55 works out of 937. Each one costs a throttled request three seconds apart,
/// so scope is what keeps a full build under three minutes rather than three
/// quarters of an hour — and estimating a release date for something dropped or
/// finished is arithmetic nobody asked for.
///
/// Hiatus works stay in scope but never get a date. Pausing the estimate is
/// more useful than guessing one, and dropping them would hide them entirely.
actor ReleaseScheduleService {
    /// The shared library walk. This service used to page the library itself
    /// — ten pages of 100, a second full walk per foreground beside the
    /// snapshot's, and a 1,000 cap against a reference library of 937 that
    /// the taste profile had already recorded hitting. The snapshot caches to
    /// disk, caps at 3,000 and says when it was cut short.
    private let library: LibrarySnapshot
    private let mangaUpdates: MangaUpdatesClient
    /// Writes to `cacheWriter`'s file: `cadenceEntry` is an estimate derived
    /// from MangaUpdates and can be measured again (Q10).
    private let database: AppDatabase
    private let clock: any Clock

    /// R20/P20: `write(seriesId:cadence:failure:)` is called through `try?`
    /// at four sites — a cadence write that throws was invisible, and every
    /// later open of that series page re-asked MangaUpdates (3 s spaced)
    /// because the write it thought had landed never did.
    private static let logger = Logger(
        subsystem: "dev.abdirahmanmohamed.mangabaka", category: "reader"
    )

    /// A cadence built from release history a fortnight old has probably missed
    /// a release since. **A guess** — a fortnight is a round number chosen to
    /// outlast a weekly series' own cadence a couple of times over; it has not
    /// been checked against how often a real estimate turns out to be missing
    /// a release at that age.
    static let staleAfter: TimeInterval = 14 * 86_400

    /// The cadence `run` and `cadence(for:)` both measure from the same
    /// release history, with the season set the same way in both. Split out
    /// after `cadence(for:)` was found measuring a cadence without ever
    /// setting `season` — the series opened from Search rather than the
    /// Schedule tab settled without one, and the settled row then blocked a
    /// later build from adding it.
    private static func measuredCadence(from releases: [MangaUpdatesClient.Release]) -> Cadence? {
        var cadence = Cadence.estimate(from: releases.compactMap(\.date))
        // Only set where the release history actually shows seasons — see
        // SeasonReading. A volume number is not a season just because the
        // series is a manhwa.
        cadence?.season = SeasonReading.currentSeason(releases.compactMap(\.sample))
        return cadence
    }

    private(set) var progress = ScheduleProgress()
    private var buildTask: Task<Void, Never>?

    init(
        library: LibrarySnapshot,
        // No default. A second `MangaUpdatesClient` means a second
        // `RequestSpacing`: two actors, two independent 3 s windows, and a 429
        // back-off earned by one invisible to the other — which is the bug this
        // parameter was added to fix, and a default would let any future call
        // site reintroduce it silently, with no build error and no failing test.
        mangaUpdates: MangaUpdatesClient,
        database: AppDatabase,
        clock: any Clock = SystemClock()
    ) {
        self.library = library
        self.mangaUpdates = mangaUpdates
        self.database = database
        self.clock = clock
    }

    // MARK: - Scope

    /// Whether a series is still going, so it belongs on the calendar at all.
    ///
    /// A completed or cancelled series will never release again. An estimate
    /// for one is not a weak answer, it is a wrong one: the page showed
    /// "Completed · 3 years overdue" for Solo Leveling, which is exactly what a
    /// median gap says about a series that stopped.
    static func canRelease(status: String?) -> Bool {
        ["releasing", "hiatus", "on_hiatus"].contains(status ?? "")
    }

    /// Whether a next chapter can honestly be predicted.
    ///
    /// Narrower than `canRelease`, and the difference is hiatus. A hiatus is a
    /// stop with no announced end, so the past rhythm has no bearing on the
    /// next chapter — the estimate reads "93 days overdue, about every 7 days,
    /// very evenly", which describes a schedule the series is no longer on. A
    /// hiatus series still belongs on the calendar; it just gets no number.
    static func canPredict(status: String?) -> Bool {
        status == "releasing"
    }

    /// Shelf states worth a release estimate: the ones the reader is partway
    /// through. Completed and dropped are finished with, whatever the series is
    /// still doing, and plan-to-read has not started.
    static let statesWorthScheduling: Set<LibraryEntry.State> = [
        .reading, .rereading, .paused
    ]

    /// Partway through, still publishing, and known to MangaUpdates.
    static func isInScope(state: LibraryEntry.State, status: String?) -> Bool {
        statesWorthScheduling.contains(state) && canRelease(status: status)
    }

    static func isPaused(status: String?) -> Bool {
        ["hiatus", "on_hiatus"].contains(status ?? "")
    }

    /// The in-scope entries from the reader's library, or why they could not
    /// be read. A failed walk used to come back as no entries, and "no entries"
    /// is what an offline reader with 900 series was then shown.
    struct Scope: Sendable {
        var entries: [LibraryEntry] = []
        var failure: APIError?
    }

    func worksInScope() async -> Scope {
        let walk = await library.load()
        let inScope = walk.entries.filter { entry in
            guard let series = entry.series else { return false }
            return Self.isInScope(state: entry.state, status: series.status)
        }
        return Scope(entries: inScope, failure: walk.failure)
    }

    // MARK: - Reading

    /// Everything estimated so far. Returns immediately, whatever is in flight.
    ///
    /// A three-minute build must never hold a screen. A half-built calendar is
    /// useful in a way a spinner is not.
    func snapshot() async -> ScheduleSnapshot {
        let scope = await worksInScope()
        let entries = scope.entries
        let cached = (try? readCache()) ?? [:]
        let now = clock.now

        var snapshot = ScheduleSnapshot()
        snapshot.inScope = entries.count
        snapshot.libraryFailure = scope.failure

        var newest: Date?
        var oldest: Date?
        for entry in entries {
            guard let series = entry.series else { continue }

            if Self.isPaused(status: series.status) {
                snapshot.undated.append(
                    ScheduledWork(series: series, cadence: nil, reason: .onHiatus)
                )
                continue
            }
            // Parseable, not merely present. A `source.manga_updates.id` this
            // app cannot turn into a number is one it can never ask about, so
            // it is a settled `.notOnMangaUpdates` — the same answer as no id
            // at all. Before 2026-09-14 only `!= nil` was checked here and in
            // `run`'s `todo` filter, while `measureOne` bailed on the parse:
            // the build counted the series done, this snapshot counted it
            // pending, and every later build re-walked it. "Reading 54 of 55
            // … 1 still to do", for the life of the account.
            guard series.mangaUpdatesID.flatMap(MangaUpdatesID.number(from:)) != nil else {
                snapshot.undated.append(
                    ScheduledWork(series: series, cadence: nil, reason: .notOnMangaUpdates)
                )
                continue
            }
            guard let row = cached[series.id], row.failure == nil else {
                // Never asked, or asked and failed. Both are "still to do".
                snapshot.pending += 1
                continue
            }

            newest = max(newest ?? row.fetchedAt, row.fetchedAt)
            oldest = min(oldest ?? row.fetchedAt, row.fetchedAt)
            if now.timeIntervalSince(row.fetchedAt) > Self.staleAfter { snapshot.stale += 1 }

            if let cadence = row.cadence {
                snapshot.dated.append(
                    ScheduledWork(series: series, cadence: cadence, reason: nil)
                )
            } else {
                // A null cadence WITH a timestamp is a settled answer, not a gap.
                snapshot.undated.append(
                    ScheduledWork(series: series, cadence: nil, reason: .tooFewReleases)
                )
            }
        }

        snapshot.dated.sort {
            ($0.cadence?.due ?? .distantFuture) < ($1.cadence?.due ?? .distantFuture)
        }
        snapshot.undated.sort {
            ($0.reason?.rawValue ?? "", $0.series.displayTitle ?? "")
                < ($1.reason?.rawValue ?? "", $1.series.displayTitle ?? "")
        }
        snapshot.measuredAt = newest
        snapshot.oldestMeasuredAt = oldest
        return snapshot
    }

    // MARK: - Building

    /// Measures every in-scope work that has not been measured yet.
    ///
    /// - Parameter refresh: re-measure everything, ignoring the cache.
    ///
    /// Returns as soon as the work is scheduled. Progress is observable through
    /// `progress`, and partial results are visible through `snapshot()` as they
    /// land — which matters on a phone, where the app can be suspended part way
    /// through a three-minute job and every completed series is banked.
    func build(refresh: Bool = false) {
        guard buildTask == nil else { return }

        // Running from this call, not from when the task gets around to
        // walking the library. A follower that asks straight after `build()`
        // returns — the schedule screen does, on the same tick — saw
        // `isRunning == false`, concluded there was nothing to follow, and
        // stopped polling a build that then ran for three minutes unwatched.
        // Deterministic on a busy simulator (the pre-push hook's iPhone 17
        // Pro failed 3 of 3), timing-dependent on an idle one.
        progress.isRunning = true
        buildID += 1
        let id = buildID
        buildTask = Task { [weak self] in
            guard let self else { return }
            await self.run(refresh: refresh)
            await self.finishBuild(id: id)
        }
    }

    /// Which build `buildTask` and `progress` currently describe.
    ///
    /// `cancelBuild` clears both synchronously *and* the cancelled task's own
    /// continuation clears them again when it unwinds. A sign-out followed by
    /// a sign-in runs `cancelBuild()` then `build()`, and the first build's
    /// late `finishBuild()` then cleared the *second* build's `buildTask` and
    /// `isRunning` while it was still measuring: the screen stopped following
    /// it, and `build()`'s `guard buildTask == nil` let a third build start
    /// alongside it. Each build now says which one it is, and only a match
    /// clears.
    private var buildID = 0

    /// Stops a build. A full one is fifty-five throttled requests three
    /// seconds apart, and until this existed nothing could stop it — the
    /// loop's cancellation check was unreachable. Signing out calls it: the
    /// series being measured are the previous account's.
    func cancelBuild() {
        buildTask?.cancel()
        finishBuild(id: buildID)
    }

    private func finishBuild(id: Int) {
        guard id == buildID else { return }
        buildTask = nil
        progress.isRunning = false
    }

    private func run(refresh: Bool) async {
        let scope = await worksInScope()
        // A build over a library that could not be read would measure nothing
        // and report itself finished. Leave it for the next attempt.
        guard scope.failure == nil else {
            progress.failure = scope.failure
            return
        }
        let entries = scope.entries
        let cached = (try? readCache()) ?? [:]

        let todo = entries.filter { entry in
            guard let series = entry.series,
                  !Self.isPaused(status: series.status),
                  // Matches `worksInScope`'s guard exactly — see its comment
                  // for the "1 still to do" that a bare `!= nil` here caused.
                  series.mangaUpdatesID.flatMap(MangaUpdatesID.number(from:)) != nil
            else { return false }
            if refresh { return true }
            guard let row = cached[series.id] else { return true }
            // Retry failures; leave settled answers alone even when null.
            return row.failure != nil
        }

        progress = ScheduleProgress(isRunning: true, done: 0, total: todo.count)

        for entry in todo {
            if Task.isCancelled { return }
            guard await measureOne(entry) else { return }
        }

        // Only after a complete pass: `entries` is the full in-scope set here,
        // so anything else in the table belongs to a series that has left the
        // library. An early `return` above skips this deliberately — a partial
        // scope is not evidence about what is out of scope.
        pruneCache(keeping: Set(entries.compactMap { $0.series?.id }))
    }

    /// Measures one series and folds the result into `progress`.
    ///
    /// - Returns: false when the build should stop entirely — a cancellation,
    ///   or a global outage (gap 99: `.offline`/`.rateLimited` will refuse
    ///   every remaining series identically, so the loop above stops rather
    ///   than spending three seconds rediscovering that 54 more times).
    ///   True otherwise, including an ordinary per-series `.server`/`.decoding`
    ///   failure, which does not say anything about the *next* series.
    private func measureOne(_ entry: LibraryEntry) async -> Bool {
        guard let series = entry.series,
              let raw = series.mangaUpdatesID,
              let number = MangaUpdatesID.number(from: raw)
        else {
            progress.done += 1
            return true
        }

        do {
            let releases = try await mangaUpdates.releases(seriesNumber: number)
            let cadence = Self.measuredCadence(from: releases)
            logWrite(seriesId: series.id, cadence: cadence, failure: nil)
            progress.done += 1
            return true
        } catch {
            guard error != .cancelled else {
                // The reader signed out or stopped the build — not a failure
                // to record or report; see `APIError.cancelled`'s own doc
                // comment on never reaching a screen.
                return false
            }
            // Recorded as a failure so the next build retries it, rather than
            // a null cadence, which would read as a settled answer.
            logWrite(seriesId: series.id, cadence: nil, failure: error.userFacingMessage)
            progress.failure = error
            progress.done += 1
            if case .offline = error { return false }
            if case .rateLimited = error { return false }
            return true
        }
    }

    /// What the schedule can say about one series.
    ///
    /// `measured` carries an estimate. `none` means MangaUpdates answered and
    /// there was not enough history to infer a rhythm — a real answer, and
    /// different from not having asked. `unavailable` means the series has no
    /// MangaUpdates id at all, so no amount of asking would help.
    enum SeriesCadence: Equatable, Sendable {
        case measured(Cadence)
        case none
        case unavailable
        /// The ask itself failed — distinct from `.none`, which is MangaUpdates
        /// answering with too little history to estimate from. Before this
        /// (gap 18) both collapsed to `.none`, so a 503 read on screen exactly
        /// like "not enough releases yet" (`DetailScheduleBlock`/`DetailHero`,
        /// batch 2).
        case failed(APIError)
    }
    /// The cadence for one series, measuring it if it has not been measured.
    ///
    /// One MangaUpdates request, not the ten pages a full build costs, and only
    /// for the series actually on screen. The client spaces requests at one
    /// every three seconds, so this can wait — which is why the screen shows a
    /// spinner rather than nothing.
    ///
    /// A settled answer is never re-fetched, including a settled "not enough
    /// history": that is a fact about the series, not a failure. A recorded
    /// failure is retried, because it is a fact about the network. A settled
    /// answer older than `staleAfter` (R7/P7) is re-measured instead of kept
    /// forever: before this, a row written once by a full build never aged,
    /// so "next chapter — 47 days late" could keep growing on a series that
    /// had shipped since, for any reader who never opens the Schedule tab's
    /// refresh. `staleAfter` is already used to *count* stale rows for the
    /// Schedule header (`snapshot()` above); this is the same threshold
    /// applied to the one row actually on screen.
    func cadence(for series: Series) async -> SeriesCadence {
        guard Self.canPredict(status: series.status) else { return .unavailable }
        guard let raw = series.mangaUpdatesID,
              let number = MangaUpdatesID.number(from: raw)
        else { return .unavailable }

        if let row = try? readCache(seriesId: series.id), row.failure == nil,
           clock.now.timeIntervalSince(row.fetchedAt) <= Self.staleAfter {
            return row.cadence.map(SeriesCadence.measured) ?? SeriesCadence.none
        }

        do {
            let releases = try await mangaUpdates.releases(seriesNumber: number)
            let cadence = Self.measuredCadence(from: releases)
            logWrite(seriesId: series.id, cadence: cadence, failure: nil)
            return cadence.map(SeriesCadence.measured) ?? SeriesCadence.none
        } catch {
            guard error != .cancelled else {
                // The same guard `measureOne` has three functions up, and it
                // was missing here: popping the page during MangaUpdates' 3 s
                // wait wrote a failure row, so the next open paid for a fresh
                // request it did not need, and `.failed(.cancelled)` reached a
                // live `DetailScheduleBlock` as an `InlineFailure` reading
                // "cancelled" — the one thing `APIError.cancelled`'s own doc
                // comment says must never be put on screen. Returned as
                // `.failed(.cancelled)` rather than swallowed here so the one
                // caller that can tell a live page from a dead one —
                // `SeriesDetailView+Store.loadCadence` — makes that call; what
                // is fixed here is the *write*, which outlives the page.
                return .failed(error)
            }
            // Recorded as a failure rather than a null cadence, so the next
            // open retries instead of treating an outage as an answer.
            logWrite(seriesId: series.id, cadence: nil, failure: error.userFacingMessage)
            return .failed(error)
        }
    }

}

/// The `cadenceEntry` table. Split into its own extension purely to keep the
/// actor body inside SwiftLint's 250-line limit — nothing about these reads
/// and writes is separable from the build above.
extension ReleaseScheduleService {
    // MARK: - Cache

    private struct CacheRow {
        let cadence: Cadence?
        let fetchedAt: Date
        let failure: String?
    }

    /// Every cached row. For the ten-page build and for `snapshot()`, which
    /// genuinely need the whole table; a single series page must use
    /// `readCache(seriesId:)` instead — this `SELECT`s and JSON-decodes all
    /// ~940 rows, and it was doing that once per series page open to find one.
    private func readCache() throws -> [Int: CacheRow] {
        try database.cacheWriter.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT seriesId, payload, fetchedAt, failure FROM cadenceEntry"
            )
            var out: [Int: CacheRow] = [:]
            for row in rows {
                out[row["seriesId"] as Int] = Self.decodeRow(row)
            }
            return out
        }
    }

    /// One cached row, by series id.
    private func readCache(seriesId: Int) throws -> CacheRow? {
        try database.cacheWriter.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT seriesId, payload, fetchedAt, failure FROM cadenceEntry WHERE seriesId = ?
                """,
                arguments: [seriesId]
            ).map(Self.decodeRow)
        }
    }

    nonisolated private static func decodeRow(_ row: Row) -> CacheRow {
        let payload: Data? = row["payload"]
        let cadence = payload.flatMap { try? JSONDecoder().decode(Cadence.self, from: $0) }
        var failure: String? = row["failure"]
        // A payload that no longer decodes — the Cadence shape moved
        // under a row an older build wrote — is not a settled "too few
        // releases". Recorded as a failure so the next build retries it.
        if payload != nil, cadence == nil, failure == nil {
            failure = "The stored estimate could not be read."
        }
        return CacheRow(cadence: cadence, fetchedAt: row["fetchedAt"], failure: failure)
    }

    /// Drops rows for series that have left the library.
    ///
    /// Nothing deleted them before, so the table only ever grew: a reader who
    /// has dropped and re-added series for two years pays for every one of
    /// them on each whole-table read above. Run at the end of a build, when
    /// the in-scope set is already known and correct — never from a
    /// single-series path, which has no idea what the whole scope is and
    /// would delete everything else.
    private func pruneCache(keeping inScope: Set<Int>) {
        guard !inScope.isEmpty else { return }
        try? database.cacheWriter.write { db in
            let placeholders = Array(repeating: "?", count: inScope.count).joined(separator: ",")
            try db.execute(
                sql: "DELETE FROM cadenceEntry WHERE seriesId NOT IN (\(placeholders))",
                arguments: StatementArguments(Array(inScope))
            )
        }
    }

    /// `write(seriesId:cadence:failure:)`, logged on failure instead of
    /// silently dropped (R20/P20) — the one place all four call sites route
    /// through, so there is one log line to add rather than four.
    private func logWrite(seriesId: Int, cadence: Cadence?, failure: String?) {
        do {
            try write(seriesId: seriesId, cadence: cadence, failure: failure)
        } catch {
            let description = String(describing: error)
            Self.logger.error(
                """
                Cadence write failed for series \(seriesId, privacy: .public): \
                \(description, privacy: .public)
                """
            )
        }
    }

    private func write(seriesId: Int, cadence: Cadence?, failure: String?) throws {
        let payload = cadence.flatMap { try? JSONEncoder().encode($0) }
        try database.cacheWriter.write { db in
            try db.execute(
                sql: """
                INSERT INTO cadenceEntry (seriesId, payload, fetchedAt, failure)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(seriesId) DO UPDATE SET
                    payload = excluded.payload,
                    fetchedAt = excluded.fetchedAt,
                    failure = excluded.failure
                """,
                arguments: [seriesId, payload, clock.now, failure]
            )
        }
    }
}
