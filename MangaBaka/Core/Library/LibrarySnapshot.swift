import Foundation
import GRDB

/// The reader's whole library, fetched once and shared.
///
/// **This is the most expensive thing the app does, by an order of magnitude.**
/// Measured on a real account on 2026-09-10: 939 entries across 13 requests,
/// **24.7 MB** — because every entry embeds its whole series, tags and all.
/// Everything else the app fetched in that session came to under 1 MB
/// combined.
///
/// And it was being walked three times a launch: once by the Library screen,
/// once to build the taste ledger, once to work out which announced releases
/// are yours. Three walks is 74 MB of someone's data allowance to draw one
/// screen.
///
/// So: one walk per session, shared. Everyone who needs the library asks here
/// and waits on the same request rather than starting their own.
actor LibrarySnapshot {
    /// Pages of a hundred, up to thirty of them — far past any real library and
    /// still bounded. See `LibraryModel` for why the old ten-page cap was a bug.
    private static let pageSize = 100
    private static let pageCap = 30

    /// What one walk produced, including why it stopped.
    ///
    /// The failure is carried rather than swallowed: an empty list and a failed
    /// request are not the same thing, and treating them as one told a reader
    /// with 937 series that they had no account whenever they opened Library on
    /// a bad connection.
    struct Result: Sendable {
        var entries: [LibraryEntry] = []
        /// False when the walk stopped early — a failure, or the page cap.
        var isComplete = true
        var failure: APIError?
    }

    /// How long a cached library stays good.
    ///
    /// Six hours, and it is discarded outright on any write — so the only way
    /// to see a stale library is to change it somewhere else, on the website or
    /// another device, and come back within six hours. The alternative is
    /// 24.7 MB every launch.
    private static let freshness: TimeInterval = 6 * 60 * 60

    private let library: any LibraryProviding
    private let database: AppDatabase?
    private let clock: any Clock
    private var cached: Result?
    private var inFlight: Task<Result, Never>?

    init(
        library: any LibraryProviding,
        database: AppDatabase? = nil,
        clock: any Clock = SystemClock()
    ) {
        self.library = library
        self.database = database
        self.clock = clock
    }

    /// Called as each page lands, so a screen can draw what has arrived rather
    /// than waiting for all of it.
    ///
    /// **This is the difference between a screen that appears and a screen that
    /// takes three and a half seconds.** 939 entries is thirteen requests at
    /// roughly 270ms each; the first hundred arrive in one of those.
    private var onPage: (@Sendable ([LibraryEntry]) -> Void)?

    func observePages(_ handler: @escaping @Sendable ([LibraryEntry]) -> Void) {
        onPage = handler
    }

    /// Everything, fetched once.
    ///
    /// Concurrent callers share one request rather than starting several — on
    /// launch all three callers arrive at once, and without this they would
    /// each begin their own walk before any of them had finished.
    func load() async -> Result {
        if let cached { return cached }
        if let inFlight { return await inFlight.value }
        // Disk before network. The answer is the same every launch and it is
        // the most expensive thing the app fetches by thirty to one.
        if let stored = readCache(), !stored.entries.isEmpty {
            cached = stored
            onPage?(stored.entries)
            return stored
        }

        let task = Task<Result, Never> { [library, onPage] in
            var result = Result()
            for page in 1...Self.pageCap {
                do throws(APIError) {
                    let batch = try await library.libraryPage(
                        page: page, limit: Self.pageSize
                    )
                    if batch.isEmpty { break }
                    result.entries.append(contentsOf: batch)
                    // The screen draws what has arrived rather than waiting
                    // for all thirteen pages.
                    onPage?(result.entries)
                    if batch.count < Self.pageSize { break }
                    // Ran out of pages before running out of library.
                    if page == Self.pageCap { result.isComplete = false }
                } catch {
                    result.failure = error
                    result.isComplete = false
                    break
                }
            }
            return result
        }
        inFlight = task
        let result = await task.value
        // A walk that failed is not cached: the next caller should try again
        // rather than inherit a bad connection for the rest of the session.
        if result.failure == nil {
            cached = result
            writeCache(result)
        }
        inFlight = nil
        // The walk is over, so nobody needs telling about pages any more.
        // Leaving the handler attached keeps the last screen's closure alive
        // for the life of the app for no reason.
        onPage = nil
        return result
    }

    /// Everything, for callers that do not care why it stopped.
    func all() async -> [LibraryEntry] { await load().entries }

    /// Just the ids, for callers that only need to know what is in there.
    func seriesIDs() async -> Set<Int> {
        Set(await all().map(\.seriesId))
    }

    /// The library as it was last written, if that was recently enough.
    private func readCache() -> Result? {
        guard let database else { return nil }
        return try? database.writer.read { db in
            guard let meta = try LibraryMetadata.fetchOne(db, key: 1) else { return nil }
            let age = clock.now.timeIntervalSince(meta.cachedAt)
            // A negative age means the device clock moved backwards; treat that
            // as stale rather than trusting it.
            guard age >= 0, age < Self.freshness else { return nil }

            let decoder = JSONDecoder()
            let rows = try CachedLibraryEntry.fetchAll(db)
            let entries = rows.compactMap {
                try? decoder.decode(LibraryEntry.self, from: $0.payload)
            }
            guard !entries.isEmpty else { return nil }
            return Result(entries: entries, isComplete: meta.isComplete, failure: nil)
        }
    }

    /// Written and read with NO key strategy, deliberately.
    ///
    /// This is a cache of our own type talking to itself, not the wire. With
    /// `convertToSnakeCase` on the way out, `LibraryEntry`'s one capitalised
    /// key — `series = "Series"`, which the API really does spell that way —
    /// was written as `"series"` and then matched nothing on the way back in.
    /// Every cached entry decoded with a nil series: 939 rows of "Untitled
    /// series" with blank covers on the second launch. Observed on device
    /// 2026-09-10. Symmetry is the fix; a strategy on one side only is the bug.
    private func writeCache(_ result: Result) {
        guard let database, !result.entries.isEmpty else { return }
        let encoder = JSONEncoder()
        try? database.writer.write { db in
            // Replaced wholesale rather than merged: an entry removed on the
            // website would otherwise survive here forever.
            try db.execute(sql: "DELETE FROM libraryEntry")
            for entry in result.entries {
                guard let payload = try? encoder.encode(entry) else { continue }
                try CachedLibraryEntry(seriesId: entry.seriesId, payload: payload).save(db)
            }
            try LibraryMetadata(
                cachedAt: clock.now, isComplete: result.isComplete
            ).save(db)
        }
    }

    /// Forgets it, so the next ask refetches.
    ///
    /// Called after a write: adding a series or changing its state makes the
    /// copy in memory wrong, and a stale library is how the app once offered
    /// "Add to library" for something already in it.
    func invalidate() {
        // The copy on disk is wrong too. A write is exactly when a stale
        // library is most visible — the reader just changed the thing they are
        // looking at.
        try? database?.writer.write { db in
            try db.execute(sql: "DELETE FROM libraryEntry")
            try db.execute(sql: "DELETE FROM libraryMetadata")
        }
        cached = nil
        inFlight?.cancel()
        inFlight = nil
    }
}
