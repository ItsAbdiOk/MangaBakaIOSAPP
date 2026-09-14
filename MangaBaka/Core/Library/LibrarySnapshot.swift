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
    /// Not private: `DetailFidelityTests` holds these values rather than
    /// grepping this file for the loop that uses them.
    nonisolated static let pageSize = 100
    nonisolated static let pageCap = 30

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
    /// Bumped by `invalidate()`. A walk that finishes after the invalidation
    /// that discarded it must not commit; see `load()`.
    private var walkGeneration = 0

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
            await Self.walk(library: library, onPage: onPage)
        }
        inFlight = task
        let myWalk = walkGeneration
        var result = await task.value
        // Only the walk that is still the current one may commit. Work-list
        // 16: this continuation used to cache, write to disk and nil `onPage`
        // unconditionally, so an `invalidate()` during a sign-out — which
        // cancels the task and clears the table — was followed moments later
        // by the discarded walk writing the *previous* account's library back
        // to memory and disk, and stealing the new walk's page observer.
        // `Task` is a struct, so this is a counter rather than an identity
        // comparison on `inFlight`.
        guard walkGeneration == myWalk else { return result }
        // Work-list 15: an edit saved while the walk was in flight had no
        // cached row to patch, so `apply` recorded it here instead; it is
        // replayed onto the finished walk before anything is cached, or the
        // pre-edit row is what sits on disk for the next six hours.
        result.entries = replayPending(onto: result.entries)
        pendingChanges.removeAll()
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

    /// The paging loop itself, lifted out of `load()` so each has one job —
    /// and so `load()` stays under the cyclomatic limit.
    ///
    /// `nonisolated static` because it touches nothing of the actor's: it gets
    /// the provider and the page handler and hands back a `Result`.
    nonisolated private static func walk(
        library: any LibraryProviding,
        onPage: (@Sendable ([LibraryEntry]) -> Void)?
    ) async -> Result {
        var result = Result()
        // Deduped by series id, first page wins. The walk used to append
        // blindly, so an entry written while it was in flight could move
        // across the page boundary and arrive twice — and both
        // `LibraryImport` and `LibraryTransferSection` build a
        // `Dictionary(uniqueKeysWithValues:)` over this, which traps on a
        // repeated key (work-list 17). `libraryPage` now also pins the order
        // with `sort_by=created_at_desc`; this is the belt to that pair of
        // braces, because the order is the server's to change.
        var seen = Set<Int>()
        for page in 1...pageCap {
            // A walk the account change already discarded must stop fetching,
            // not just stop being cached (work-list 16).
            if Task.isCancelled { break }
            do throws(APIError) {
                let batch = try await library.libraryPage(page: page, limit: pageSize)
                if batch.isEmpty { break }
                result.entries += batch.filter { seen.insert($0.seriesId).inserted }
                // The screen draws what has arrived rather than waiting for
                // all thirteen pages.
                onPage?(result.entries)
                if batch.count < pageSize { break }
                // Ran out of pages before running out of library.
                if page == pageCap { result.isComplete = false }
            } catch {
                result.failure = error
                result.isComplete = false
                break
            }
        }
        return result
    }

    /// Edits that landed while the walk was still in flight, newest per
    /// series. Applied to the walk's own rows before they are cached; see
    /// `apply(seriesId:change:)`.
    private var pendingChanges: [Int: LibraryChange] = [:]

    private func replayPending(onto entries: [LibraryEntry]) -> [LibraryEntry] {
        guard !pendingChanges.isEmpty else { return entries }
        return entries.map { entry in
            guard let change = pendingChanges[entry.seriesId] else { return entry }
            return entry.applying(change)
        }
    }

    /// The cached walk, or nil when nothing is cached.
    ///
    /// Read-only, and the one way a test can tell "nothing cached" from
    /// "cached and empty" — `all()` would start a walk to answer that, which
    /// is exactly the thing under test in `discardedWalkDoesNotCommit`.
    var cachedResult: Result? { cached }

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
            // Gap 116: a row that no longer decodes — an app downgrade, a
            // format this build dropped — was silently left out, and the
            // walk that wrote 939 rows quietly read back as complete with
            // 938. Falling through to the network here means one bad row
            // costs a re-fetch rather than a permanently shrunk library that
            // never shows as anything but whole.
            guard entries.count == rows.count else { return nil }
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
                // `insert`, not `save`: the table was emptied one statement
                // ago, so GRDB's `save` spends an UPDATE that matches nothing
                // before every INSERT — ~1,900 statements for 945 rows, once
                // per walk (work-list 92). The dedupe in `load()` is what
                // makes this safe: `insert` would throw on a repeated id.
                try CachedLibraryEntry(seriesId: entry.seriesId, payload: payload).insert(db)
            }
            try LibraryMetadata(
                cachedAt: clock.now, isComplete: result.isComplete
            ).save(db)
        }
    }

    /// Patches one entry in the shared snapshot, in memory and on disk,
    /// without a network call.
    ///
    /// Gap 88/j (decision 5): a write used to invalidate the whole snapshot
    /// and re-walk the library — 13 requests, 24.7 MB on a real account — to
    /// reflect one changed row. This updates the cached copy directly, so a
    /// caller that already knows what the server now holds (because it just
    /// wrote it) can show that immediately.
    ///
    /// A no-op when the entry is not in the cached snapshot yet — nothing has
    /// been walked this session, or the row is new. The caller falls back to
    /// `invalidate()` and a real reload in that case; there is no local row
    /// here to patch.
    func apply(seriesId: Int, change: LibraryChange) {
        // Work-list 15: an edit saved during the walk had nothing cached to
        // patch, so it was dropped here — and the walk then cached the
        // pre-edit row for six hours, which is how a rating set on the
        // Library screen reappeared as its old value on the next launch.
        // Stashed and replayed onto the walk's own rows in `load()`.
        if cached == nil, inFlight != nil {
            pendingChanges[seriesId] = pendingChanges[seriesId]?.merging(change) ?? change
            return
        }
        guard var result = cached,
              let index = result.entries.firstIndex(where: { $0.seriesId == seriesId })
        else { return }
        let patched = result.entries[index].applying(change)
        result.entries[index] = patched
        cached = result
        writeSingleEntry(patched)
    }

    /// Rewrites one row of the disk cache, leaving the rest and the metadata
    /// untouched. `writeCache` replaces the whole table and is for a fresh
    /// walk; a single patched entry does not need — and must not pay for —
    /// re-encoding the other 938.
    private func writeSingleEntry(_ entry: LibraryEntry) {
        guard let database else { return }
        guard let payload = try? JSONEncoder().encode(entry) else { return }
        try? database.writer.write { db in
            try CachedLibraryEntry(seriesId: entry.seriesId, payload: payload).save(db)
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
        // A walk still in flight belongs to the account being forgotten, and
        // so do any edits stashed against it (work-list 15/16).
        walkGeneration += 1
        pendingChanges.removeAll()
    }
}
