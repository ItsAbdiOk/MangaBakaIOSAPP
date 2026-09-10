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
    func absorb(_ entries: [LibraryEntry]) throws {
        try database.writer.write { db in
            for entry in entries {
                guard let series = entry.series else { continue }
                let tags = series.richTags
                guard !tags.isEmpty else { continue }

                let previous = try TasteSource.fetchOne(db, key: entry.seriesId)
                if previous?.state == entry.state.rawValue { continue }

                // Undo the old contribution before adding the new one, or a
                // series that moved from reading to dropped would keep the
                // weight of both.
                if let previous, let old = LibraryEntry.State(rawValue: previous.state) {
                    try Self.apply(tags, multiplier: -Self.weight(old), to: db)
                }
                try Self.apply(tags, multiplier: Self.weight(entry.state), to: db)

                try TasteSource(
                    seriesId: entry.seriesId,
                    countedAt: clock.now,
                    state: entry.state.rawValue
                ).save(db)
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
        try database.writer.read { db in
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
        try database.writer.read { db in try TasteSource.fetchCount(db) }
    }

    /// How many distinct tags are known, whatever their score.
    ///
    /// Reported in Settings beside the counted series, because the two
    /// together diagnose the one failure this feature can have quietly: series
    /// counted but no tags known means the library's own payload carries no
    /// tags, and nothing on screen would otherwise say so.
    func knownTags() throws -> Int {
        try database.writer.read { db in try TagAffinity.fetchCount(db) }
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
    func absorb(_ series: Series, as state: LibraryEntry.State) throws {
        let tags = series.richTags
        guard !tags.isEmpty else { return }
        try database.writer.write { db in
            let previous = try TasteSource.fetchOne(db, key: series.id)
            if previous?.state == state.rawValue { return }
            if let previous, let old = LibraryEntry.State(rawValue: previous.state) {
                try Self.apply(tags, multiplier: -Self.weight(old), to: db)
            }
            try Self.apply(tags, multiplier: Self.weight(state), to: db)
            try TasteSource(
                seriesId: series.id, countedAt: clock.now, state: state.rawValue
            ).save(db)
            try Self.prune(db)
        }
    }

    /// Forgets everything learned. Paired with clearing the library or signing
    /// out: a taste profile built from someone else's library would be worse
    /// than none.
    func clear() throws {
        _ = try database.writer.write { db in
            try TagAffinity.deleteAll(db)
            try TasteSource.deleteAll(db)
        }
    }

    /// Adds (or subtracts) one series' tags.
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
    private static func apply(_ tags: [SeriesTag], multiplier: Double, to db: Database) throws {
        guard multiplier != 0 else { return }
        let step = multiplier > 0 ? 1 : -1
        let statement = try db.makeStatement(sql: """
            INSERT INTO tagAffinity (tagId, name, score, seriesCount)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(tagId) DO UPDATE SET
                score = score + excluded.score,
                seriesCount = MAX(0, seriesCount + excluded.seriesCount),
                name = excluded.name
            """)
        for tag in tags {
            try statement.execute(arguments: [
                tag.id, tag.name, weight(tag.importance) * multiplier, step
            ])
        }
    }

    /// Drops tags that have fallen to nothing, so removing a series from the
    /// library actually removes its influence rather than leaving a zero row.
    private static func prune(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM tagAffinity WHERE score <= 0 OR seriesCount <= 0")
    }
}
