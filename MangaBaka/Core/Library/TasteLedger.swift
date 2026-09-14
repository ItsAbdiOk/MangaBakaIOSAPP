import Foundation
import GRDB

/// Which tags actually run through the reader's own library.
///
/// **Why this exists.** The API's taste endpoint,
/// `/v1/my/series/discover/top-genres`, answers in *genres* — and a genre is
/// almost none of what a series is tagged with. Solo Leveling carries 146 tags
/// and exactly six of them are genres: Fantasy, Action, Adventure, Drama,
/// Horror, Tragedy. So the most that endpoint can ever say is "you like
/// fantasy". It cannot say "you read a lot of Regression, Murim and Tower
/// Climbing", which is the thing a reader actually recognises about themselves.
///
/// **Why it costs nothing.** Checked against the live API on 2026-09-10: v1
/// list responses embed the whole `tags_v2` array — 146 tags came back inside a
/// one-result search. The library endpoint returns the same v1 series objects,
/// so every page the app already fetches carries its tags. No extra request is
/// made for this, ever. If a library response turns out to omit `tags_v2` the
/// ledger simply stays empty and the app falls back to genres, which is the
/// behaviour it had before.
///
/// **What it is not.** It never leaves the device, and it is derived from the
/// library rather than from browsing: what you *read* counts, what you looked
/// at does not.
actor TasteLedger {
    /// Writes to `libraryWriter`'s file: the ledger is derived from the
    /// reader's library and from nothing the network can return (Q10).
    private let database: AppDatabase
    private let clock: any Clock

    init(database: AppDatabase, clock: any Clock = SystemClock()) {
        self.database = database
        self.clock = clock
    }

    /// How much a tag's presence in one series is worth.
    ///
    /// Straight from `tags_v2`'s own weighting, which is the API saying how
    /// central the tag is to *that* series. A core tag describes the book; an
    /// incidental one happens in it.
    private static func weight(_ importance: SeriesTag.Weight) -> Double {
        switch importance {
        case .core: 4
        case .defining: 3
        case .recurrent: 2
        case .incidental, .unweighted: 1
        }
    }

    /// How much a series counts, by what the reader did with it.
    ///
    /// Dropped still counts, at a third. Abdi asked for that explicitly on
    /// 2026-09-10 — "even with series that I've dropped" — and he is right:
    /// dropping a series after forty chapters is evidence of what you read,
    /// even though it is not evidence of what you liked. It is scored lower
    /// than finishing one because it is weaker evidence, not because it is
    /// none.
    ///
    /// Plan-to-read and considering score zero. Nothing has been read, so
    /// counting them would measure ambition rather than habit.
    private static func weight(_ state: LibraryEntry.State) -> Double {
        switch state {
        case .reading, .rereading, .completed: 3
        case .paused: 2
        case .dropped: 1
        case .planToRead, .considering: 0
        }
    }

    /// Counts a page of library entries into the ledger.
    ///
    /// Safe to call with the same entries repeatedly: a series is counted once
    /// per state, and moving it from reading to dropped recounts it at the new
    /// weight rather than adding a second set of tags on top.
    ///
    /// `entries` here is always the *whole* current library, not a page — see
    /// `TasteProfile.buildIDs`. That is what makes it possible to detect a
    /// removal: a `TasteSource` row whose series is not in `entries` was
    /// dropped from the library since the last call and its contribution is
    /// retracted below (R9).
    /// Counts the reader's library into the ledger, from a walk that says how
    /// it went.
    ///
    /// **Takes the `Result`, not its entries, because the retraction below
    /// cannot tell the two empties apart.** Work-list 5: `TasteProfile` fed
    /// this `snapshot.all()`, which is `[]` for a failed walk exactly as it is
    /// for an empty library, so opening one series page while offline — or
    /// inside a rate-limit window, or with the API 500ing — matched every
    /// `tasteSource` row as stale and retracted all of them. On Abdi's real
    /// install that is 945 sources and ~3,175 tags, per the `v11_recountTaste`
    /// measurement. It rebuilds on the next successful walk, at the cost of the
    /// 939-select/939-upsert pass `absorb(_ series:)` exists to avoid paying.
    ///
    /// A page-capped walk is refused for the same reason a failed one is: the
    /// sweep's whole premise is that `entries` is everything.
    func absorb(_ library: LibrarySnapshot.Result) throws {
        try absorb(library.entries, retractingMissing: library.isWholeLibrary)
    }

    /// - Parameter retractingMissing: whether `entries` is known to be the
    ///   reader's *whole* library, so that a `tasteSource` row missing from it
    ///   means the series left the library rather than that the walk stopped
    ///   short. There is no default: the caller has to say, because getting
    ///   this wrong silently empties the ledger. Prefer `absorb(_ library:)`,
    ///   which answers it from the walk itself.
    func absorb(_ entries: [LibraryEntry], retractingMissing: Bool) throws {
        try database.libraryWriter.write { db in
            for entry in entries {
                guard let series = entry.series else { continue }
                try TasteSeen(seriesId: entry.seriesId).save(db)
                let tags = series.richTags
                guard !tags.isEmpty else { continue }

                let previous = try TasteSource.fetchOne(db, key: entry.seriesId)
                if previous?.state == entry.state.rawValue { continue }

                // Undo the old contribution before adding the new one, or a
                // series that moved from reading to dropped would keep the
                // weight of both. Reads what was actually added last time
                // from `tasteContribution` rather than re-deriving it from
                // `previous.state`, so it stays correct even if the series'
                // own tags changed between calls.
                try Self.retract(seriesId: entry.seriesId, in: db)
                try Self.contribute(
                    tags, seriesId: entry.seriesId, multiplier: Self.weight(entry.state), to: db
                )

                try TasteSource(
                    seriesId: entry.seriesId,
                    countedAt: clock.now,
                    state: entry.state.rawValue
                ).save(db)
            }

            // R9: a series removed from the library used to keep its weight
            // forever — `absorb` only ever added and re-weighted, and the
            // `prune` doc below claimed removal removed influence although no
            // code path did that. `TasteSource` rows not present in this full
            // snapshot are exactly the series that dropped out since the last
            // absorb; retract what they contributed and forget them.
            //
            // Only when `entries` really is the whole library. With an empty
            // array the predicate is `NOT 0`, which matches every row, so a
            // failed walk retracted the entire ledger (work-list 5).
            if retractingMissing {
                let presentIDs = entries.map(\.seriesId)
                let stale = try TasteSource
                    .filter(!presentIDs.contains(Column("seriesId")))
                    .fetchAll(db)
                for source in stale {
                    try Self.retract(seriesId: source.seriesId, in: db)
                    try source.delete(db)
                }
            }

            try Self.prune(db)
        }
    }

    /// The reader's own tags, strongest first.
    ///
    /// - Parameter limit: how many to treat as theirs. Thirty is enough to
    ///   reach into most groups on a series page without the highlight
    ///   becoming meaningless by covering everything.
    func favoured(limit: Int = 30) throws -> [TagAffinity] {
        try database.libraryWriter.read { db in
            try TagAffinity
                // Two series minimum. One is a coincidence — every library has
                // a single series carrying some tag nobody would claim as a
                // taste.
                .filter(Column("seriesCount") >= 2)
                .order(Column("score").desc, Column("seriesCount").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func favouredIDs(limit: Int = 30) throws -> Set<Int> {
        Set(try favoured(limit: limit).map(\.tagId))
    }

    /// How many of the reader's series have been counted, for diagnosis and
    /// for a screen that wants to say where the numbers came from.
    func countedSeries() throws -> Int {
        try database.libraryWriter.read { db in try TasteSource.fetchCount(db) }
    }

    /// How many series the ledger was offered at all, tagged or not.
    ///
    /// The diagnostic below compares this against `countedSeries`: series
    /// seen but not counted carried no tags. Before this existed the failure
    /// it was built to catch was unreachable — a tagless series was skipped
    /// before it was counted, so "counted but no tags" could never happen.
    func seenSeries() throws -> Int {
        try database.libraryWriter.read { db in try TasteSeen.fetchCount(db) }
    }

    /// How many distinct tags are known, whatever their score.
    ///
    /// Reported in Settings beside the counted series, because the two
    /// together diagnose the one failure this feature can have quietly: series
    /// counted but no tags known means the library's own payload carries no
    /// tags, and nothing on screen would otherwise say so.
    func knownTags() throws -> Int {
        try database.libraryWriter.read { db in try TagAffinity.fetchCount(db) }
    }

    /// Counts one series the app has met somewhere else — a feed, a search, a
    /// series page — at the weight of whatever the reader did with it.
    ///
    /// **The library's own payload may not carry tags.** Its embedded series
    /// arrives under a capitalised `Series` key and has never been checked for
    /// `tags_v2` against a live authenticated response, because the only token
    /// available here is rejected. Every other payload in the app definitely
    /// does carry them — verified on `/v1/series/search` and `/v1/series/{id}`
    /// — so this is the path that cannot silently produce nothing.
    /// - Returns: whether any affinity actually moved. False for the common
    ///   case — a series already counted in the same state, which is what
    ///   every reopen of a series page is. `TasteProfile.note` uses this to
    ///   decide whether to drop its cached ids: dropping them
    ///   unconditionally meant the next `favouredTagIDs()` re-absorbed all
    ///   ~939 library entries (939 selects, 939 upserts and a `NOT IN` scan)
    ///   on every single series page open, with the page's tag ordering
    ///   waiting on it.
    @discardableResult
    func absorb(_ series: Series, as state: LibraryEntry.State) throws -> Bool {
        let tags = series.richTags
        return try database.libraryWriter.write { db in
            try TasteSeen(seriesId: series.id).save(db)
            guard !tags.isEmpty else { return false }
            let previous = try TasteSource.fetchOne(db, key: series.id)
            if previous?.state == state.rawValue { return false }
            try Self.retract(seriesId: series.id, in: db)
            try Self.contribute(tags, seriesId: series.id, multiplier: Self.weight(state), to: db)
            try TasteSource(
                seriesId: series.id, countedAt: clock.now, state: state.rawValue
            ).save(db)
            try Self.prune(db)
            return true
        }
    }

    /// Forgets everything learned. Paired with clearing the library or signing
    /// out: a taste profile built from someone else's library would be worse
    /// than none.
    func clear() throws {
        try database.libraryWriter.write { db in
            for table in Self.tables {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
    }

    /// The tables the ledger *is*.
    ///
    /// Named once because three places have to agree about this list and they
    /// already did not. Work-list 12: `clear()` deleted `tagAffinity`,
    /// `tasteSource` and `tasteContribution` and left `tasteSeen`, so after a
    /// sign-out — `RootView+Session` calls `forgetEverything()` there precisely
    /// so no account-scoped data survives — `DataUseSection` read `seenSeries`
    /// first and Settings said "945 series seen, and none of them carried
    /// tags": the previous account's count, dressed up as this feature's one
    /// diagnosable failure. `v11_recountTaste` already deleted `tasteSeen`, so
    /// the migration and the clear disagreed about what forgetting the ledger
    /// means.
    ///
    /// `v11` is not derived from this list on purpose: it is a recorded
    /// migration and what it did on the devices that have run it cannot be
    /// changed, so it keeps its three literal statements.
    /// `TasteLedgerTests.everyLedgerTableIsAReaderTable` is what stops this
    /// list and `AppDatabase.readerTables` drifting apart.
    nonisolated static let tables = [
        "tagAffinity", "tasteSource", "tasteSeen", "tasteContribution"
    ]

    /// Adds one series' tags to `tagAffinity`, and records exactly what was
    /// added in `tasteContribution` so it can be taken back later without
    /// needing the series' tags again — see `retract`.
    ///
    /// **One statement per tag, no read.** This used to fetch each row, add to
    /// it in Swift, and save it back — two round trips per tag, per series.
    /// Measured at 517ms for 200 series of 40 tags, which for a real library of
    /// 939 with up to 146 tags each is several seconds of the first launch
    /// after signing in. The upsert does the arithmetic in SQLite, inside the
    /// transaction that was already open.
    ///
    /// `MAX(0, ...)` on the count rather than in Swift for the same reason: it
    /// is the database's job and doing it here would need the read back.
    private static func contribute(
        _ tags: [SeriesTag], seriesId: Int, multiplier: Double, to db: Database
    ) throws {
        guard multiplier != 0 else { return }
        let affinityStatement = try db.makeStatement(sql: """
            INSERT INTO tagAffinity (tagId, name, score, seriesCount)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(tagId) DO UPDATE SET
                score = score + excluded.score,
                seriesCount = MAX(0, seriesCount + excluded.seriesCount),
                name = excluded.name
            """)
        let contributionStatement = try db.makeStatement(sql: """
            INSERT INTO tasteContribution (seriesId, tagId, name, score)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(seriesId, tagId) DO UPDATE SET score = excluded.score, name = excluded.name
            """)
        for tag in tags {
            let score = weight(tag.importance) * multiplier
            try affinityStatement.execute(arguments: [tag.id, tag.name, score, 1])
            try contributionStatement.execute(arguments: [seriesId, tag.id, tag.name, score])
        }
    }

    /// Undoes whatever `tasteContribution` says `seriesId` last added to
    /// `tagAffinity`, then forgets it. A series with no recorded contribution
    /// (never counted, or already retracted) leaves nothing to undo here.
    private static func retract(seriesId: Int, in db: Database) throws {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT tagId, name, score FROM tasteContribution WHERE seriesId = ?",
            arguments: [seriesId]
        )
        guard !rows.isEmpty else { return }
        let statement = try db.makeStatement(sql: """
            INSERT INTO tagAffinity (tagId, name, score, seriesCount)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(tagId) DO UPDATE SET
                score = score + excluded.score,
                seriesCount = MAX(0, seriesCount + excluded.seriesCount),
                name = excluded.name
            """)
        for row in rows {
            let tagId: Int = row["tagId"]
            let name: String = row["name"]
            let score: Double = row["score"]
            try statement.execute(arguments: [tagId, name, -score, -1])
        }
        try db.execute(sql: "DELETE FROM tasteContribution WHERE seriesId = ?", arguments: [seriesId])
    }

    /// Drops tags that have fallen to nothing, so removing a series from the
    /// library actually removes its influence rather than leaving a zero row.
    private static func prune(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM tagAffinity WHERE score <= 0 OR seriesCount <= 0")
    }
}
