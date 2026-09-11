import Foundation
import GRDB

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
    var measuredAt: Date?

    var isEmpty: Bool { dated.isEmpty && undated.isEmpty }
}

/// Progress of a background build.
struct ScheduleProgress: Equatable, Sendable {
    var isRunning = false
    var done = 0
    var total = 0
    var failure: String?

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
    private let library: any LibraryProviding
    private let mangaUpdates: MangaUpdatesClient
    private let database: AppDatabase
    private let clock: any Clock

    /// A cadence built from release history a fortnight old has probably missed
    /// a release since.
    static let staleAfter: TimeInterval = 14 * 86_400

    private(set) var progress = ScheduleProgress()
    private var buildTask: Task<Void, Never>?

    init(
        library: any LibraryProviding,
        mangaUpdates: MangaUpdatesClient = MangaUpdatesClient(),
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
        var all: [LibraryEntry] = []
        var failure: APIError?
        // The library pages at 100; ten pages covers a very large library and
        // caps the cost of a caller that would otherwise loop forever.
        for page in 1...10 {
            let batch: [LibraryEntry]
            do {
                batch = try await library.libraryPage(page: page, limit: 100)
            } catch {
                failure = error
                break
            }
            if batch.isEmpty { break }
            all.append(contentsOf: batch)
            if batch.count < 100 { break }
        }
        let inScope = all.filter { entry in
            guard let series = entry.series else { return false }
            return Self.isInScope(state: entry.state, status: series.status)
        }
        return Scope(entries: inScope, failure: failure)
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
        for entry in entries {
            guard let series = entry.series else { continue }

            if Self.isPaused(status: series.status) {
                snapshot.undated.append(
                    ScheduledWork(series: series, cadence: nil, reason: .onHiatus)
                )
                continue
            }
            guard series.mangaUpdatesID != nil else {
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

        buildTask = Task { [weak self] in
            guard let self else { return }
            await self.run(refresh: refresh)
            await self.finishBuild()
        }
    }
    private func finishBuild() {
        buildTask = nil
        progress.isRunning = false
    }

    private func run(refresh: Bool) async {
        let scope = await worksInScope()
        // A build over a library that could not be read would measure nothing
        // and report itself finished. Leave it for the next attempt.
        guard scope.failure == nil else {
            progress.failure = scope.failure?.userFacingMessage
            return
        }
        let entries = scope.entries
        let cached = (try? readCache()) ?? [:]

        let todo = entries.filter { entry in
            guard let series = entry.series,
                  !Self.isPaused(status: series.status),
                  series.mangaUpdatesID != nil
            else { return false }
            if refresh { return true }
            guard let row = cached[series.id] else { return true }
            // Retry failures; leave settled answers alone even when null.
            return row.failure != nil
        }

        progress = ScheduleProgress(isRunning: true, done: 0, total: todo.count)

        for entry in todo {
            if Task.isCancelled { return }
            guard let series = entry.series,
                  let raw = series.mangaUpdatesID,
                  let number = MangaUpdatesID.number(from: raw)
            else {
                progress.done += 1
                continue
            }

            do {
                let releases = try await mangaUpdates.releases(seriesNumber: number)
                var cadence = Cadence.estimate(from: releases.compactMap(\.date))
                // Only set where the release history actually shows seasons —
                // see SeasonReading. A volume number is not a season just
                // because the series is a manhwa.
                cadence?.season = SeasonReading.currentSeason(releases.compactMap(\.sample))
                try? write(seriesId: series.id, cadence: cadence, failure: nil)
            } catch {
                // Recorded as a failure so the next build retries it, rather
                // than a null cadence, which would read as a settled answer.
                try? write(seriesId: series.id, cadence: nil, failure: error.userFacingMessage)
                progress.failure = error.userFacingMessage
            }
            progress.done += 1
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
    /// failure is retried, because it is a fact about the network.
    func cadence(for series: Series) async -> SeriesCadence {
        guard Self.canPredict(status: series.status) else { return .unavailable }
        guard let raw = series.mangaUpdatesID,
              let number = MangaUpdatesID.number(from: raw)
        else { return .unavailable }

        if let row = (try? readCache())?[series.id], row.failure == nil {
            return row.cadence.map(SeriesCadence.measured) ?? SeriesCadence.none
        }

        do {
            let releases = try await mangaUpdates.releases(seriesNumber: number)
            let cadence = Cadence.estimate(from: releases.compactMap(\.date))
            try? write(seriesId: series.id, cadence: cadence, failure: nil)
            return cadence.map(SeriesCadence.measured) ?? SeriesCadence.none
        } catch {
            // Recorded as a failure rather than a null cadence, so the next
            // open retries instead of treating an outage as an answer.
            try? write(seriesId: series.id, cadence: nil, failure: error.userFacingMessage)
            return .none
        }
    }

    // MARK: - Cache

    private struct CacheRow {
        let cadence: Cadence?
        let fetchedAt: Date
        let failure: String?
    }

    private func readCache() throws -> [Int: CacheRow] {
        try database.writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT seriesId, payload, fetchedAt, failure FROM cadenceEntry"
            )
            let decoder = JSONDecoder()
            var out: [Int: CacheRow] = [:]
            for row in rows {
                let id: Int = row["seriesId"]
                let payload: Data? = row["payload"]
                let cadence = payload.flatMap { try? decoder.decode(Cadence.self, from: $0) }
                var failure: String? = row["failure"]
                // A payload that no longer decodes — the Cadence shape moved
                // under a row an older build wrote — is not a settled "too few
                // releases". Recorded as a failure so the next build retries it.
                if payload != nil, cadence == nil, failure == nil {
                    failure = "The stored estimate could not be read."
                }
                out[id] = CacheRow(cadence: cadence, fetchedAt: row["fetchedAt"], failure: failure)
            }
            return out
        }
    }

    private func write(seriesId: Int, cadence: Cadence?, failure: String?) throws {
        let payload = cadence.flatMap { try? JSONEncoder().encode($0) }
        try database.writer.write { db in
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
