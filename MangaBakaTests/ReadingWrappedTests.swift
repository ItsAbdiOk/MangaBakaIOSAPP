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
struct ReadingWrappedTests {
    private func tag(_ id: Int, _ name: String, world: Int, spoiler: Bool = false) -> SeriesTag {
        SeriesTag(
            id: id, name: name, namePath: nil, isGenre: false, isSpoiler: spoiler,
            isExplicit: false, impliedByTagIds: nil, contentRating: nil,
            weight: "core", seriesCount: world
        )
    }

    private func libraryEntry(
        _ id: Int,
        state: LibraryEntry.State = .completed,
        read: Double? = nil,
        total: Double? = nil,
        rating: Double? = nil,
        crowdRating: Double? = nil,
        ratingCount: Int? = nil,
        start: Date? = nil,
        finish: Date? = nil,
        type: String = "manhwa",
        year: Int? = nil,
        authors: [String]? = nil,
        tags: [SeriesTag] = []
    ) -> LibraryEntry {
        LibraryEntry(
            id: id, seriesId: id, state: state, progressChapter: read,
            progressVolume: nil, rating: rating, note: nil,
            startDate: start, finishDate: finish,
            numberOfRereads: nil, priority: nil, isPrivate: nil, readLink: nil,
            series: SeriesFactory.make(
                id: id, title: "S\(id)", authors: authors, rating: crowdRating,
                type: type, totalChapters: total, year: year,
                ratingCount: ratingCount, tagsV2: tags.isEmpty ? nil : tags
            )
        )
    }

    private func day(_ iso: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: iso) ?? .distantPast
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

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

    // MARK: - Obscurity

    @Test("The deepest cut is something you actually read")
    func deepestCutMustBeStarted() throws {
        // The most obscure thing on a plan-to-read shelf is something the
        // reader has not read, which is not a fact about them.
        let entries = [
            libraryEntry(1, state: .planToRead, ratingCount: 3),
            libraryEntry(2, state: .completed, ratingCount: 40),
            libraryEntry(3, state: .completed, ratingCount: 9_000)
        ]
        #expect(try #require(ReadingWrapped.deepestCut(in: entries)).seriesId == 2)
    }

    // MARK: - The year

    @Test("A year is what you finished in it")
    func yearFiltersByFinishDate() {
        let entries = [
            libraryEntry(1, total: 100, finish: day("2026-03-04")),
            libraryEntry(2, total: 50, finish: day("2026-11-20")),
            libraryEntry(3, total: 999, finish: day("2025-12-31")),
            libraryEntry(4)
        ]
        let year = ReadingWrapped.year(2026, in: entries, calendar: utc)

        #expect(year.finished.map(\.seriesId) == [2, 1], "newest first")
        #expect(year.chapters == 150, "the 2025 finish is not in this year")
        #expect(year.dated == 3)
        #expect(year.total == 4)
    }

    @Test("A year says how much of the library it could see")
    func yearReportsItsCoverage() {
        // Finish dates are set by the site when a series is completed there,
        // and not otherwise. A year built from four of nine hundred entries is
        // a different claim from one built from all of them.
        let entries = (1...10).map { libraryEntry($0, finish: $0 <= 2 ? day("2026-05-05") : nil) }
        let year = ReadingWrapped.year(2026, in: entries, calendar: utc)
        #expect(year.coverage == 0.2)
        #expect(!year.isWorthShowing, "two finishes is a list, not a year")
    }

    @Test("A tied busiest month is not reported")
    func tiedMonthsAreSilent() {
        // "Your busiest month was March, or possibly July" is not a fact worth
        // printing, and picking one at random is worse.
        let entries = [
            libraryEntry(1, finish: day("2026-03-01")),
            libraryEntry(2, finish: day("2026-07-01"))
        ]
        let year = ReadingWrapped.year(2026, in: entries, calendar: utc)
        #expect(ReadingWrapped.busiestMonth(in: year, calendar: utc) == nil)
    }

    @Test("A clear busiest month is")
    func busiestMonthIsFound() throws {
        let entries = [
            libraryEntry(1, finish: day("2026-03-01")),
            libraryEntry(2, finish: day("2026-03-14")),
            libraryEntry(3, finish: day("2026-07-01"))
        ]
        let year = ReadingWrapped.year(2026, in: entries, calendar: utc)
        let month = try #require(ReadingWrapped.busiestMonth(in: year, calendar: utc))
        #expect(month.month == 3)
        #expect(month.count == 2)
    }

    @Test("A oneshot is not the fastest read of your life")
    func sprintsNeedARealRun() {
        // One chapter finished the day it was started is technically the
        // fastest reading anybody has ever done.
        let entries = [
            libraryEntry(1, read: 1, total: 1, start: day("2026-01-01"), finish: day("2026-01-01"))
        ]
        #expect(ReadingWrapped.fastestFinish(in: entries, calendar: utc) == nil)
    }

    @Test("A binge is")
    func sprintIsFound() throws {
        let entries = [
            libraryEntry(1, total: 200, start: day("2026-01-01"), finish: day("2026-01-05")),
            libraryEntry(2, total: 200, start: day("2026-01-01"), finish: day("2026-06-01"))
        ]
        let sprint = try #require(ReadingWrapped.fastestFinish(in: entries, calendar: utc))
        #expect(sprint.entry.seriesId == 1)
        #expect(sprint.perDay == 50)
    }

    @Test("Same-day finishes count as one day, not none")
    func sameDayIsOneDay() throws {
        let entries = [
            libraryEntry(1, total: 60, start: day("2026-02-02"), finish: day("2026-02-02"))
        ]
        let sprint = try #require(ReadingWrapped.fastestFinish(in: entries, calendar: utc))
        #expect(sprint.perDay == 60)
    }

    @Test("A whole series logged on one day is a backfill, not a binge")
    func backfillsAreRejected() {
        // Found on a real 939-entry library: the screen announced "700
        // chapters a day — NARUTO, 700 chapters in 1 day". Nobody read Naruto
        // in a day. A series marked completed with both dates set to that
        // moment is what every importer and most bulk edits produce.
        let entries = [
            libraryEntry(1, total: 700, start: day("2026-01-01"),
                         finish: day("2026-01-01"), type: "manga"),
            libraryEntry(2, total: 120, start: day("2026-02-01"),
                         finish: day("2026-02-03"), type: "manhwa")
        ]
        let sprint = ReadingWrapped.fastestFinish(in: entries, calendar: utc)
        #expect(sprint?.entry.seriesId == 2, "the real binge, not the import")
    }

    @Test("A genuine binge is not rejected with the backfills")
    func realBingesSurvive() {
        // 40 manhwa chapters in a day is four hours. Extraordinary, possible,
        // and exactly the kind of thing this card exists to celebrate.
        let entries = [
            libraryEntry(1, total: 40, start: day("2026-03-01"),
                         finish: day("2026-03-01"), type: "manhwa")
        ]
        #expect(ReadingWrapped.fastestFinish(in: entries, calendar: utc)?.perDay == 40)
    }

    @Test("The thing you have been reading longest is still unfinished")
    func longestRunningIsUnfinished() throws {
        let entries = [
            libraryEntry(1, state: .reading, start: day("2019-04-01")),
            libraryEntry(2, state: .completed, start: day("2015-01-01"), finish: day("2016-01-01")),
            libraryEntry(3, state: .reading, start: day("2024-01-01"))
        ]
        #expect(try #require(ReadingWrapped.longestRunning(in: entries)).seriesId == 1)
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
