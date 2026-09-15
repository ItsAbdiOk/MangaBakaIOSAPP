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

    @Test("The gap is shown in the reader's own stars")
    func disagreementDisplaysInStars() throws {
        // Ratings are 0-100 in the API; the reader rates in five stars. The
        // gap is about their rating, so it is in their units — a "+24" would
        // be nonsense, and so would a "+2.4" to someone who has only ever
        // seen a 5.
        let entries = [libraryEntry(1, rating: 94, crowdRating: 70)]
        let liked = try #require(ReadingWrapped.disagreements(in: entries, liked: true).first)
        #expect(liked.displayGap == "+1.2 stars")
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

    /// L5: `WrappedView`'s critic caveat used to always read `loved.first`
    /// regardless of which way the headline pointed — a harsh critic (a
    /// negative `critic.gap`, "a tough crowd of one") got a caveat naming
    /// their mildest *overrating*, never the harsher underrating that
    /// actually produced the headline.
    /// Expected to fail with the old `loved.first`-always logic: on a harsh
    /// critic the caveat would name series 1 (id 1, the overrated pick), not
    /// series 2 (id 2, the underrated one the negative headline is about).
    @Test("The critic caveat names the disagreement in the headline's own direction")
    func caveatMatchesHeadlineDirection() {
        let overrated = ReadingWrapped.Disagreement(
            entry: libraryEntry(1, rating: 95, crowdRating: 60), gap: 35
        )
        let underrated = ReadingWrapped.Disagreement(
            entry: libraryEntry(2, rating: 40, crowdRating: 85), gap: -45
        )

        let harshCritic = WrappedView.furthestDisagreement(
            critic: (gap: -20, sample: 12), loved: [overrated], disliked: [underrated]
        )
        #expect(harshCritic?.id == 2, "a negative headline gap should name the underrated series")

        let generousReader = WrappedView.furthestDisagreement(
            critic: (gap: 20, sample: 12), loved: [overrated], disliked: [underrated]
        )
        #expect(generousReader?.id == 1, "a positive headline gap should name the overrated series")
    }

    /// If the reader's largest disagreement is negative and they have never
    /// overrated anything, `loved` is empty — the caveat must not vanish just
    /// because the wrong list happens to be the one it always read from.
    @Test("A harsh critic with nothing overrated still gets a caveat")
    func caveatSurvivesAnEmptyLovedList() {
        let underrated = ReadingWrapped.Disagreement(
            entry: libraryEntry(2, rating: 40, crowdRating: 85), gap: -45
        )
        let furthest = WrappedView.furthestDisagreement(
            critic: (gap: -20, sample: 12), loved: [], disliked: [underrated]
        )
        #expect(furthest?.id == 2)
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

    @Test("A creator you read once is not a creator you follow")
    func creatorsNeedRepetition() {
        let entries = [
            libraryEntry(1, authors: ["Chugong"]),
            libraryEntry(2, authors: ["Chugong"]),
            libraryEntry(3, authors: ["Someone Else"])
        ]
        #expect(ReadingWrapped.creators(in: entries).map(\.label) == ["Chugong"])
    }

    // MARK: - Count-up

    /// The pure decision behind `CountUpNumber`: what to show partway
    /// through a headline stat's count-up animation, at 0 (just landed),
    /// 0.5 (halfway) and 1 (settled) — the three points the motion brief
    /// asks for explicitly.
    @Test("A headline number counts up from 0 to its target")
    func countUpProgresses() {
        #expect(WrappedView.countUp(progress: 0, target: 42) == 0)
        #expect(WrappedView.countUp(progress: 0.5, target: 42) == 21)
        #expect(WrappedView.countUp(progress: 1, target: 42) == 42)
    }

    @Test("Progress outside 0...1 is clamped, not trusted")
    func countUpClampsProgress() {
        // `CountUpNumber` derives progress from elapsed time minus a stagger
        // delay, which is negative before the delay has passed and can run
        // past 1 on a dropped frame — neither should read as a number outside
        // the card's own range.
        #expect(WrappedView.countUp(progress: -0.4, target: 42) == 0)
        #expect(WrappedView.countUp(progress: 1.8, target: 42) == 42)
    }

    @Test("A count-up rounds rather than truncates")
    func countUpRounds() {
        // At 90% of a target of 10, truncating would still show 9 — visually
        // indistinguishable from "stuck" for the last tenth of the animation.
        // Rounding shows 10 slightly early, which reads as arriving, not stalling.
        #expect(WrappedView.countUp(progress: 0.96, target: 10) == 10)
    }

    // MARK: - Arrival haptic latch

    @Test("An arrival haptic fires once, never again for the same card")
    func arrivalHapticFiresOnce() {
        // `#expect` captures its expression in an autoclosure, where a
        // mutating call on a captured var is not allowed — so fire first.
        var latch = ArrivalHapticLatch()
        let first = latch.fireOnce()
        let second = latch.fireOnce()
        let third = latch.fireOnce()
        #expect(first, "the first arrival should fire")
        #expect(!second, "a second call for the same card must not fire again")
        #expect(!third, "and neither should a third")
    }
}
