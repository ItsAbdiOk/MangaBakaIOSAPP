import Testing
import Foundation
@testable import MangaBaka

/// The local taste profile: which tags actually run through the reader's own
/// library.
///
/// This exists because the API's own taste endpoint answers in genres, and six
/// of Solo Leveling's 146 tags are genres. These tests pin the behaviour that
/// makes the local count worth having.
@Suite("Taste ledger")
struct TasteLedgerTests {
    private func tag(_ id: Int, _ name: String, weight: String) -> SeriesTag {
        SeriesTag(
            id: id, name: name, namePath: nil, isGenre: false, isSpoiler: false,
            isExplicit: false, impliedByTagIds: nil, contentRating: nil,
            weight: weight, seriesCount: nil
        )
    }

    private func entry(
        _ seriesId: Int,
        _ state: LibraryEntry.State,
        tags: [SeriesTag]
    ) -> LibraryEntry {
        LibraryEntry(
            id: seriesId, seriesId: seriesId, state: state, progressChapter: nil,
            progressVolume: nil, rating: nil, note: nil, startDate: nil,
            finishDate: nil, numberOfRereads: nil, priority: nil, isPrivate: nil,
            readLink: nil, series: SeriesFactory.make(id: seriesId, tagsV2: tags)
        )
    }

    private func ledger() throws -> TasteLedger {
        TasteLedger(database: try AppDatabase.inMemory(), clock: TestClock())
    }

    @Test("A core tag outscores an incidental one")
    func weighsByHowCentralTheTagIs() async throws {
        let ledger = try ledger()
        try await ledger.absorb([
            entry(1, .completed, tags: [
                tag(10, "Regression", weight: "core"),
                tag(11, "Cooking", weight: "incidental")
            ]),
            entry(2, .completed, tags: [
                tag(10, "Regression", weight: "core"),
                tag(11, "Cooking", weight: "incidental")
            ])
        ], retractingMissing: true)

        let favoured = try await ledger.favoured()
        #expect(favoured.first?.name == "Regression")
        let cooking = try #require(favoured.first { $0.name == "Cooking" })
        let regression = try #require(favoured.first { $0.name == "Regression" })
        #expect(regression.score > cooking.score)
    }

    @Test("A dropped series still counts, and counts for less than a finished one")
    func dropsCountLessButStillCount() async throws {
        let dropped = try ledger()
        try await dropped.absorb([
            entry(1, .dropped, tags: [tag(10, "Murim", weight: "core")]),
            entry(2, .dropped, tags: [tag(10, "Murim", weight: "core")])
        ], retractingMissing: true)
        let finished = try ledger()
        try await finished.absorb([
            entry(1, .completed, tags: [tag(10, "Murim", weight: "core")]),
            entry(2, .completed, tags: [tag(10, "Murim", weight: "core")])
        ], retractingMissing: true)

        let droppedScore = try #require(try await dropped.favoured().first).score
        let finishedScore = try #require(try await finished.favoured().first).score
        #expect(droppedScore > 0, "Abdi asked for dropped series to count")
        #expect(finishedScore > droppedScore)
    }

    @Test("Plan-to-read counts for nothing — it has not been read")
    func ignoresUnreadStates() async throws {
        let ledger = try ledger()
        try await ledger.absorb([
            entry(1, .planToRead, tags: [tag(10, "Isekai", weight: "core")]),
            entry(2, .considering, tags: [tag(10, "Isekai", weight: "core")])
        ], retractingMissing: true)

        #expect(try await ledger.favoured().isEmpty)
    }

    /// The Settings diagnostic "counted but no tags" exists to catch a library
    /// payload without tags. A tagless series was skipped before it was
    /// counted, so the diagnostic could never fire.
    @Test("A series without tags is seen, so the diagnostic can say so")
    func taglessSeriesIsSeen() async throws {
        let ledger = try ledger()
        try await ledger.absorb([
            entry(1, .completed, tags: []),
            entry(2, .completed, tags: [tag(1, "Murim", weight: "core")])
        ], retractingMissing: true)
        #expect(try await ledger.seenSeries() == 2)
        #expect(try await ledger.countedSeries() == 1)
    }

    @Test("Absorbing the same library twice does not count it twice")
    func isIdempotent() async throws {
        let ledger = try ledger()
        let entries = [
            entry(1, .completed, tags: [tag(10, "Murim", weight: "core")]),
            entry(2, .completed, tags: [tag(10, "Murim", weight: "core")])
        ]
        try await ledger.absorb(entries, retractingMissing: true)
        let once = try #require(try await ledger.favoured().first).score

        try await ledger.absorb(entries, retractingMissing: true)
        let twice = try #require(try await ledger.favoured().first).score

        #expect(once == twice)
        #expect(try await ledger.countedSeries() == 2)
    }

    @Test("Moving a series to dropped recounts it rather than adding to it")
    func recountsOnStateChange() async throws {
        let ledger = try ledger()
        try await ledger.absorb([
            entry(1, .completed, tags: [tag(10, "Murim", weight: "core")]),
            entry(2, .completed, tags: [tag(10, "Murim", weight: "core")])
        ], retractingMissing: true)
        let before = try #require(try await ledger.favoured().first).score

        // The whole library again, as `TasteProfile` always passes it: a
        // series missing from the list is read as removed (R9).
        try await ledger.absorb([
            entry(1, .dropped, tags: [tag(10, "Murim", weight: "core")]),
            entry(2, .completed, tags: [tag(10, "Murim", weight: "core")])
        ], retractingMissing: true)
        let after = try #require(try await ledger.favoured().first).score

        #expect(after < before, "one of the two dropped, so the tag matters less")
        #expect(try await ledger.favoured().first?.seriesCount == 2)
    }

    /// R9: `absorb` only ever added and re-weighted; nothing subtracted a
    /// series no longer in the library, so it kept its weight forever. Fixed
    /// by retracting a `TasteSource` row's contribution when the full
    /// snapshot passed to `absorb` no longer contains it.
    @Test("A series removed from the library loses its weight")
    func removalRetractsWeight() async throws {
        let ledger = try ledger()
        try await ledger.absorb([
            entry(1, .completed, tags: [tag(10, "Murim", weight: "core")]),
            entry(2, .completed, tags: [tag(10, "Murim", weight: "core")]),
            entry(3, .completed, tags: [tag(10, "Murim", weight: "core")])
        ], retractingMissing: true)
        let before = try #require(try await ledger.favoured().first { $0.name == "Murim" })
        #expect(before.seriesCount == 3)

        // A full snapshot without series 3 — `absorb` always receives the
        // whole library, never a page, so this is what "removed" looks like.
        try await ledger.absorb([
            entry(1, .completed, tags: [tag(10, "Murim", weight: "core")]),
            entry(2, .completed, tags: [tag(10, "Murim", weight: "core")])
        ], retractingMissing: true)

        let after = try #require(try await ledger.favoured().first { $0.name == "Murim" })
        #expect(after.seriesCount == 2, "the removed series should stop counting")
        #expect(after.score < before.score)
        #expect(try await ledger.countedSeries() == 2)
    }

    @Test("Removing every series with a tag drops the tag entirely")
    func fullRemovalDropsTheTag() async throws {
        let ledger = try ledger()
        try await ledger.absorb([
            entry(1, .completed, tags: [tag(10, "Murim", weight: "core")]),
            entry(2, .completed, tags: [tag(10, "Murim", weight: "core")])
        ], retractingMissing: true)
        #expect(try await ledger.favoured().contains { $0.name == "Murim" })

        try await ledger.absorb([], retractingMissing: true)

        #expect(!(try await ledger.favoured().contains { $0.name == "Murim" }))
        #expect(try await ledger.countedSeries() == 0)
        #expect(try await ledger.knownTags() == 0)
    }

    @Test("A tag in a single series is a coincidence, not a taste")
    func needsMoreThanOneSeries() async throws {
        let ledger = try ledger()
        try await ledger.absorb([
            entry(1, .completed, tags: [
                tag(10, "Murim", weight: "core"),
                tag(99, "Beekeeping", weight: "core")
            ]),
            entry(2, .completed, tags: [tag(10, "Murim", weight: "core")])
        ], retractingMissing: true)

        let names = try await ledger.favoured().map(\.name)
        #expect(names.contains("Murim"))
        #expect(!names.contains("Beekeeping"))
    }

    /// Work-list 5, the one that empties the ledger.
    ///
    /// EXPECTED TO FAIL ON THE OLD CODE with: `absorb` took `[LibraryEntry]`
    /// and always swept, so `absorb(failedWalk.entries)` — `[]` — matched
    /// every `tasteSource` row (`presentIDs.contains` on an empty array is
    /// `NOT 0` in SQL, which is true of every row), retracted all of them and
    /// deleted them. `#expect(countedSeries() == 2)` would read **0** and
    /// `knownTags()` would read 0 too. On Abdi's real install that is 945
    /// sources and ~3,175 tags, thrown away by opening one series page while
    /// offline.
    ///
    /// The control is `fullRemovalDropsTheTag` above: a genuinely emptied
    /// library, passed as `retractingMissing: true`, must still sweep. Without
    /// it a `guard !entries.isEmpty` patch would pass this test and silently
    /// stop retraction working at all.
    @Test("A failed library walk does not empty the ledger")
    func aFailedWalkRetractsNothing() async throws {
        let ledger = try ledger()
        try await ledger.absorb([
            entry(1, .completed, tags: [tag(10, "Murim", weight: "core")]),
            entry(2, .completed, tags: [tag(10, "Murim", weight: "core")])
        ], retractingMissing: true)
        #expect(try await ledger.countedSeries() == 2)

        // Exactly what `LibrarySnapshot.load()` answers when the reader is
        // offline, or rate-limited, or the API 500s: no entries, and the
        // reason why.
        let failedWalk = LibrarySnapshot.Result(
            entries: [], isComplete: false, failure: .offline
        )
        #expect(failedWalk.isWholeLibrary == false)
        try await ledger.absorb(failedWalk)

        #expect(try await ledger.countedSeries() == 2, "a failed walk retracted the whole ledger")
        #expect(try await ledger.knownTags() == 1)
        #expect(try await ledger.favoured().contains { $0.name == "Murim" })
    }

    /// A walk that stopped at the thirty-page cap is short, not wrong — but it
    /// is not everything either, so it must not sweep. Same mechanism as
    /// `aFailedWalkRetractsNothing`, different signal.
    @Test("A page-capped walk does not retract the series it did not reach")
    func aPageCappedWalkRetractsNothing() async throws {
        let ledger = try ledger()
        try await ledger.absorb([
            entry(1, .completed, tags: [tag(10, "Murim", weight: "core")]),
            entry(2, .completed, tags: [tag(10, "Murim", weight: "core")])
        ], retractingMissing: true)

        let short = LibrarySnapshot.Result(
            entries: [entry(1, .completed, tags: [tag(10, "Murim", weight: "core")])],
            isComplete: false,
            failure: nil
        )
        try await ledger.absorb(short)

        #expect(try await ledger.countedSeries() == 2)
    }

    /// Work-list 12.
    ///
    /// EXPECTED TO FAIL ON THE OLD CODE with: `clear()` deleted `tagAffinity`,
    /// `tasteSource` and `tasteContribution` and never touched `tasteSeen`, so
    /// `#expect(seenSeries() == 0)` would read **1**. On a real install it read
    /// 945, and because `DataUseSection` checks `seenSeries` first, Settings
    /// told a signed-out reader "945 series seen, and none of them carried
    /// tags" — the previous account's count, printed as this feature's one
    /// diagnosable failure.
    @Test("Signing out forgets that the ledger ever saw a series")
    func clearForgetsSeenSeriesToo() async throws {
        let ledger = try ledger()
        // Tagless on purpose: a series that is *seen* and never *counted* is
        // the only one that reaches `tasteSeen` and nothing else.
        try await ledger.absorb([entry(1, .reading, tags: [])], retractingMissing: true)
        #expect(try await ledger.seenSeries() == 1)

        try await ledger.clear()

        #expect(try await ledger.seenSeries() == 0)
        #expect(try await ledger.countedSeries() == 0)
        #expect(try await ledger.knownTags() == 0)
    }

    /// The three hand-maintained copies of "which tables are the ledger" —
    /// `v11_recountTaste`, `clear()`, and `salvage`'s `readerTables` — already
    /// disagreed, which is how work-list 12 happened. A source pin rather than
    /// a behaviour test, and it is here because the alternative is finding out
    /// from a reader.
    @Test("Every ledger table is one of the reader's tables")
    func everyLedgerTableIsAReaderTable() {
        for table in TasteLedger.tables {
            #expect(
                AppDatabase.readerTables.contains(table),
                "\(table) is in the ledger but not in readerTables, so a split or a salvage drops it"
            )
        }
    }

    @Test("Favoured tags sort to the front of their group, and are marked as the reader's")
    func favouredTagsLeadTheirGroup() throws {
        let tags = [
            tag(1, "Zebra", weight: "core"),
            tag(2, "Murim", weight: "incidental")
        ]
        let groups = TagGrouping.groups(from: tags, allowedRatings: nil, favouredIDs: [2])

        let group = try #require(groups.first)
        #expect(
            group.tags.map(\.name) == ["Murim", "Zebra"],
            "the reader's own tag leads, even though it matters less to this series"
        )
    }
}

/// Counting a series the app met somewhere other than the library payload.
///
/// The library's own entries may carry no tags — its embedded series arrives
/// under a capitalised `Series` key and has never been checked against a live
/// authenticated response, because the only token here is rejected. Every other
/// payload in the app does carry them, so this is the path that cannot silently
/// produce nothing.
@Suite("Taste from series the app opens")
struct TasteFromSeriesTests {
    private func tag(_ id: Int, _ name: String) -> SeriesTag {
        SeriesTag(
            id: id, name: name, namePath: nil, isGenre: false, isSpoiler: false,
            isExplicit: false, impliedByTagIds: nil, contentRating: nil,
            weight: "core", seriesCount: nil
        )
    }

    @Test("Opening a series you are reading counts its tags")
    func countsAnOpenedSeries() async throws {
        let ledger = TasteLedger(database: try AppDatabase.inMemory(), clock: TestClock())
        let tags = [tag(1, "Murim"), tag(2, "Male Protagonist")]

        try await ledger.absorb(SeriesFactory.make(id: 10, tagsV2: tags), as: .reading)
        try await ledger.absorb(SeriesFactory.make(id: 11, tagsV2: tags), as: .completed)

        let names = try await ledger.favoured().map(\.name)
        #expect(names.contains("Murim"))
        #expect(names.contains("Male Protagonist"))
        #expect(try await ledger.knownTags() == 2)
    }

    @Test("Signing in as someone else forgets what the last account taught it")
    func forgettingClearsTheLedger() async throws {
        // A taste profile built from one person's library, still on disk after
        // a different token is entered, is worse than no profile: every
        // recommendation is then about somebody else's reading. `clear()`
        // existed for this and nothing called it — found by Periphery, and it
        // is a behavioural gap, not dead code.
        let ledger = TasteLedger(database: try AppDatabase.inMemory(), clock: TestClock())
        let tags = [tag(1, "Murim"), tag(2, "Male Protagonist")]
        try await ledger.absorb(SeriesFactory.make(id: 10, tagsV2: tags), as: .reading)
        try await ledger.absorb(SeriesFactory.make(id: 11, tagsV2: tags), as: .completed)
        #expect(try await ledger.countedSeries() == 2)

        let profile = TasteProfile(library: NoLibrary(), ledger: ledger)
        await profile.forgetEverything()

        #expect(try await ledger.countedSeries() == 0)
        #expect(try await ledger.knownTags() == 0)
        #expect(try await ledger.favoured().isEmpty)
    }

    @Test("A series with no tags is not counted as a source")
    func skipsUntaggedSeries() async throws {
        // Otherwise it is recorded as counted, and the next payload that DOES
        // carry its tags is skipped as already done.
        let ledger = TasteLedger(database: try AppDatabase.inMemory(), clock: TestClock())
        try await ledger.absorb(SeriesFactory.make(id: 10), as: .reading)

        #expect(try await ledger.countedSeries() == 0)
        #expect(try await ledger.knownTags() == 0)
    }

    @Test("The same series counted twice does not count twice")
    func idempotentPerState() async throws {
        let ledger = TasteLedger(database: try AppDatabase.inMemory(), clock: TestClock())
        let tags = [tag(1, "Murim"), tag(2, "Regression")]
        let series = SeriesFactory.make(id: 10, tagsV2: tags)
        // A second series, because a tag on one is a coincidence and `favoured`
        // deliberately will not report it.
        try await ledger.absorb(SeriesFactory.make(id: 11, tagsV2: tags), as: .reading)

        try await ledger.absorb(series, as: .reading)
        let once = try #require(try await ledger.favoured(limit: 30).first { $0.name == "Murim" })
        try await ledger.absorb(series, as: .reading)
        let twice = try #require(try await ledger.favoured(limit: 30).first { $0.name == "Murim" })

        #expect(once.score == twice.score)
        #expect(once.seriesCount == twice.seriesCount)
    }

    @Test("Counted series and known tags are both reported")
    func diagnosticsTellTheTruth() async throws {
        // Series counted with zero tags known is the signature of a payload
        // that carries no tags, and it is invisible without both numbers.
        let ledger = TasteLedger(database: try AppDatabase.inMemory(), clock: TestClock())
        try await ledger.absorb(
            SeriesFactory.make(id: 10, tagsV2: [tag(1, "Murim")]), as: .reading
        )

        #expect(try await ledger.countedSeries() == 1)
        #expect(try await ledger.knownTags() == 1)
    }
}

/// A library that answers nothing. `TasteProfile` needs one to exist; the
/// forgetting test is about the ledger on disk, not about the API.
private final class NoLibrary: LibraryProviding, @unchecked Sendable {
    func library(page: Int, limit: Int) async -> [LibraryEntry] { [] }
    func recommendationStatus() async throws(APIError) -> RecommendationStatus {
        throw APIError.offline
    }
    func recommendations(limit: Int, page: Int, excluding: [Int]) async -> PersonalRecommendations {
        PersonalRecommendations()
    }
    func hiddenTagIDs() async -> Set<Int>? { [] }
    func topGenres() async -> [TopGenre]? { [] }
    func update(seriesId: Int, change: LibraryChange) async throws(APIError) {}
    func add(seriesId: Int, state: LibraryEntry.State) async throws(APIError) -> Bool { true }
    func remove(seriesId: Int) async throws(APIError) {}
}
