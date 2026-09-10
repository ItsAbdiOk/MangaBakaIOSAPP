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
        ])

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
        ])
        let finished = try ledger()
        try await finished.absorb([
            entry(1, .completed, tags: [tag(10, "Murim", weight: "core")]),
            entry(2, .completed, tags: [tag(10, "Murim", weight: "core")])
        ])

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
        ])

        #expect(try await ledger.favoured().isEmpty)
    }

    @Test("Absorbing the same library twice does not count it twice")
    func isIdempotent() async throws {
        let ledger = try ledger()
        let entries = [
            entry(1, .completed, tags: [tag(10, "Murim", weight: "core")]),
            entry(2, .completed, tags: [tag(10, "Murim", weight: "core")])
        ]
        try await ledger.absorb(entries)
        let once = try #require(try await ledger.favoured().first).score

        try await ledger.absorb(entries)
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
        ])
        let before = try #require(try await ledger.favoured().first).score

        try await ledger.absorb([
            entry(1, .dropped, tags: [tag(10, "Murim", weight: "core")])
        ])
        let after = try #require(try await ledger.favoured().first).score

        #expect(after < before, "one of the two dropped, so the tag matters less")
        #expect(try await ledger.favoured().first?.seriesCount == 2)
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
        ])

        let names = try await ledger.favoured().map(\.name)
        #expect(names.contains("Murim"))
        #expect(!names.contains("Beekeeping"))
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
