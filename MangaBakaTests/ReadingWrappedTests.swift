import Testing
import Foundation
@testable import MangaBaka

/// The reader's year, and the parts of their taste that are actually theirs.
///
/// The rule the whole file is built on: a statistic is only interesting if it
/// could have come out differently. "Your top tag is Action" is a fact about
/// manga, not about the reader. These tests exist mostly to pin the places
/// where that rule is easy to break.
@Suite("Wrapped")
struct ReadingWrappedTests: WrappedFixtures {
    // MARK: - Signatures

    @Test("A tag everyone reads is not a fact about you")
    func commonTagsAreNotSignatures() {
        // Action is on a third of the database. Three of your nine series
        // having it is exactly what the database predicts, and printing that
        // as a personality trait is the thing this whole file exists to avoid.
        let action = tag(1, "Action", world: 100_000)
        let other = tag(9, "Drama", world: 100_000)
        var entries = (1...3).map { libraryEntry($0, tags: [action]) }
        entries += (4...9).map { libraryEntry($0, tags: [other]) }
        let signatures = ReadingWrapped.signatures(in: entries, catalogueSize: 300_000)

        #expect(
            !signatures.contains { $0.tag == "Action" },
            "a tag read at the database's own rate is not a signature"
        )
    }

    @Test("Reading something slightly more than average is noise")
    func weakLiftIsNotASignature() {
        // 1.5x is the kind of number that differs between two random halves of
        // the same library.
        let tepid = tag(8, "Comedy", world: 60_000)
        var entries = (1...6).map { libraryEntry($0, tags: [tepid]) }
        entries += (7...20).map { libraryEntry($0, tags: [tag(7, "Drama", world: 60_000)]) }
        let signatures = ReadingWrapped.signatures(in: entries, catalogueSize: 300_000)
        #expect(!signatures.contains { $0.tag == "Comedy" })
    }

    @Test("A rare tag you read constantly is")
    func rareTagsAreSignatures() throws {
        // 8 of 10 series, against a tag on 1% of the database.
        let regression = tag(2, "Regression", world: 3_000)
        let filler = tag(3, "Action", world: 100_000)
        var entries = (1...8).map { libraryEntry($0, tags: [regression, filler]) }
        entries += (9...10).map { libraryEntry($0, tags: [filler]) }

        let signatures = ReadingWrapped.signatures(in: entries, catalogueSize: 300_000)
        let top = try #require(signatures.first)

        #expect(top.tag == "Regression")
        #expect(top.mine == 8)
        // 80% of the library against 1% of the database.
        #expect(top.lift > 70)
    }

    @Test("A spoiler tag is never shown")
    func spoilersAreExcluded() {
        // A wrapped screen that announces "you read a lot of Character Death"
        // has spoiled something for whoever is looking over the reader's
        // shoulder.
        let death = tag(4, "Character Death", world: 2_000, spoiler: true)
        let entries = (1...9).map { libraryEntry($0, tags: [death]) }
        #expect(ReadingWrapped.signatures(in: entries, catalogueSize: 300_000).isEmpty)
    }

    @Test("Four series sharing a tag is a coincidence")
    func smallCountsAreNotSignatures() {
        let niche = tag(5, "Cooking", world: 900)
        let entries = (1...4).map { libraryEntry($0, tags: [niche]) }
        #expect(ReadingWrapped.signatures(in: entries, catalogueSize: 300_000).isEmpty)
    }

    // MARK: - Disagreement

    @Test("Too few ratings is answered with nothing, not with zero")
    func criticGapNeedsASample() {
        let entries = (1...9).map { libraryEntry($0, rating: 90, crowdRating: 70) }
        #expect(ReadingWrapped.criticGap(in: entries) == nil)
    }

    @Test("A harsh critic reads as negative")
    func criticGapIsSigned() throws {
        let entries = (1...12).map { libraryEntry($0, rating: 60, crowdRating: 80) }
        let result = try #require(ReadingWrapped.criticGap(in: entries))
        #expect(result.gap == -20)
        #expect(result.sample == 12)
    }

    @Test("The gap is shown on the scale the app shows ratings in")
    func disagreementDisplaysOnTheTenScale() throws {
        // Ratings are 0-100 in the API and 0-10 on screen. A "+24" would be
        // nonsense next to an 8.6.
        let entries = [libraryEntry(1, rating: 94, crowdRating: 70)]
        let liked = try #require(ReadingWrapped.disagreements(in: entries, liked: true).first)
        #expect(liked.displayGap == "+2.4")
    }

    @Test("Overrated and underrated are separate questions")
    func disagreementsSplitBySign() {
        let entries = [
            libraryEntry(1, rating: 95, crowdRating: 60),
            libraryEntry(2, rating: 40, crowdRating: 85)
        ]
        #expect(ReadingWrapped.disagreements(in: entries, liked: true).map(\.id) == [1])
        #expect(ReadingWrapped.disagreements(in: entries, liked: false).map(\.id) == [2])
    }

    // MARK: - Only what was read counts

    /// A 400-entry plan-to-read shelf is ambition, not habit. Every statistic
    /// whose caption says "read" has to leave it out — `verdicts` and the
    /// taste ledger already do, and four of these did not.
    @Test("Series never opened count for nothing")
    func unreadSeriesAreExcluded() {
        let rare = tag(1, "Kuudere", world: 100)
        let unread = (1...6).map {
            libraryEntry(
                $0, state: .planToRead, type: "novel", year: 1995, authors: ["Backlog"], tags: [rare]
            )
        }
        let read = [
            libraryEntry(10, state: .completed, type: "manhwa", year: 2021, authors: ["Chugong"]),
            libraryEntry(11, state: .reading, type: "manhwa", year: 2022, authors: ["Chugong"])
        ]
        let entries = unread + read

        #expect(ReadingWrapped.signatures(in: entries, catalogueSize: 300_000).isEmpty)
        #expect(ReadingWrapped.formats(in: entries).map(\.label) == ["Manhwa"])
        #expect(ReadingWrapped.decades(in: entries).map(\.label) == ["2020s"])
        #expect(ReadingWrapped.creators(in: entries).map(\.label) == ["Chugong"])
    }

    /// An importer that writes 0 for "unrated" would otherwise make the reader
    /// a savage critic of ten series they never rated. `verdicts` guards this.
    @Test("A zero rating is not a rating")
    func zeroRatingIsUnrated() {
        let entries = (1...12).map { libraryEntry($0, rating: 0, crowdRating: 75) }
        #expect(ReadingWrapped.criticGap(in: entries) == nil)
        #expect(ReadingWrapped.disagreements(in: entries, liked: false).isEmpty)
    }

    // MARK: - Composition

    @Test("Formats are counted, largest first")
    func formatsAreTallied() {
        let entries = (1...3).map { libraryEntry($0, type: "manhwa") } + [libraryEntry(4, type: "manga")]
        #expect(ReadingWrapped.formats(in: entries).map(\.label) == ["Manhwa", "Manga"])
    }

    @Test("Decades run in time order, not by size")
    func decadesAreChronological() {
        let entries = [libraryEntry(1, year: 2021), libraryEntry(2, year: 1998), libraryEntry(3, year: 2023)]
        #expect(ReadingWrapped.decades(in: entries).map(\.label) == ["1990s", "2020s"])
    }

    @Test("A creator you read once is not a creator you follow")
    func creatorsNeedRepetition() {
        let entries = [
            libraryEntry(1, authors: ["Chugong"]),
            libraryEntry(2, authors: ["Chugong"]),
            libraryEntry(3, authors: ["Someone Else"])
        ]
        #expect(ReadingWrapped.creators(in: entries).map(\.label) == ["Chugong"])
    }
}
