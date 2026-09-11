import Testing
import Foundation
@testable import MangaBaka

/// What the reader's own library says about them.
///
/// None of these questions has an endpoint, and no catalogue could answer them:
/// they are about one person's reading rather than about the books. The
/// judgements — what counts as behind, what counts as nearly finished — are the
/// part worth pinning.
@Suite("Reading insights")
struct ReadingInsightsTests {
    private func tag(_ id: Int, _ name: String) -> SeriesTag {
        SeriesTag(
            id: id, name: name, namePath: nil, isGenre: false, isSpoiler: false,
            isExplicit: false, impliedByTagIds: nil, contentRating: nil,
            weight: "core", seriesCount: nil
        )
    }

    private func entry(
        _ id: Int,
        _ state: LibraryEntry.State,
        read: Double? = nil,
        total: Double? = nil,
        status: String? = "releasing",
        rating: Double? = nil,
        type: String = "manhwa",
        tags: [SeriesTag] = []
    ) -> LibraryEntry {
        LibraryEntry(
            id: id, seriesId: id, state: state, progressChapter: read,
            progressVolume: nil, rating: rating, note: nil, startDate: nil,
            finishDate: nil, numberOfRereads: nil, priority: nil, isPrivate: nil,
            readLink: nil,
            series: SeriesFactory.make(
                id: id, title: "S\(id)", status: status, type: type,
                totalChapters: total, tagsV2: tags.isEmpty ? nil : tags
            )
        )
    }

    // MARK: - Waiting

    @Test("Most waiting first, and one chapter behind is not news")
    func waitingIsOrderedAndFiltered() {
        // A weekly series is one behind for six days out of seven. Telling
        // someone that is how a feature gets switched off.
        let rows = ReadingInsights.waiting(in: [
            entry(1, .reading, read: 10, total: 11),
            entry(2, .reading, read: 10, total: 50),
            entry(3, .paused, read: 5, total: 12)
        ])

        #expect(rows.map(\.entry.seriesId) == [2, 3])
        #expect(rows.first?.waiting == 40)
    }

    @Test("Only things you were actually reading")
    func waitingIgnoresUnreadStates() {
        // Plan-to-read is not a backlog, it is a wish list. Counting it would
        // put a hundred series you never started into "waiting for you".
        let rows = ReadingInsights.waiting(in: [
            entry(1, .planToRead, read: 0, total: 200),
            entry(2, .completed, read: 0, total: 200),
            entry(3, .dropped, read: 3, total: 200)
        ])

        #expect(rows.isEmpty)
    }

    @Test("A series you never opened is not something you fell behind on")
    func waitingRequiresAStart() {
        // The section's own subtitle says "chapters published since you
        // stopped". You cannot have stopped something you never started. On
        // the device this made the list a ranking of the longest series in the
        // library: "The Devil Butler, ch 0 of 889, 889 behind".
        let rows = ReadingInsights.waiting(in: [
            entry(1, .reading, read: 0, total: 889),
            entry(2, .reading, read: nil, total: 232),
            entry(3, .paused, read: 4, total: 240)
        ])

        #expect(rows.map(\.entry.seriesId) == [3])
        #expect(rows.first?.waiting == 236)
    }

    @Test("A series with no chapter count is not guessed about")
    func waitingNeedsATotal() {
        #expect(ReadingInsights.waiting(in: [entry(1, .reading, read: 10, total: nil)]).isEmpty)
    }

    // MARK: - Nearly finished

    @Test("A short completed series you never opened is not nearly finished")
    func nearlyFinishedAlsoNeedsAStart() {
        // The same bug as "waiting": a five-chapter completed series with no
        // progress recorded is five chapters LEFT, which satisfied "within 12"
        // and read as "you are nearly done". You are not; you never began.
        let rows = ReadingInsights.nearlyFinished(in: [
            entry(1, .reading, read: 0, total: 5, status: "completed"),
            entry(2, .reading, read: nil, total: 5, status: "completed"),
            entry(3, .reading, read: 3, total: 5, status: "completed")
        ])
        #expect(rows.map(\.entry.seriesId) == [3])
    }

    @Test("Ended, and you are a few chapters short")
    func nearlyFinishedIsNarrow() {
        let rows = ReadingInsights.nearlyFinished(in: [
            entry(1, .reading, read: 196, total: 200, status: "completed"),
            // Forty from the end of a finished series is a different feeling
            // and belongs in the backlog, not in "it finished without telling
            // you".
            entry(2, .reading, read: 160, total: 200, status: "completed"),
            // Still running: it has not finished, so nothing finished quietly.
            entry(3, .reading, read: 196, total: 200, status: "releasing"),
            // Already done.
            entry(4, .reading, read: 200, total: 200, status: "completed")
        ])

        #expect(rows.map(\.entry.seriesId) == [1])
        #expect(rows.first?.waiting == 4)
    }

    @Test("Closest to the end comes first")
    func nearlyFinishedOrdersByHowCloseYouAre() {
        let rows = ReadingInsights.nearlyFinished(in: [
            entry(1, .reading, read: 190, total: 200, status: "completed"),
            entry(2, .reading, read: 199, total: 200, status: "completed")
        ])
        #expect(rows.map(\.entry.seriesId) == [2, 1])
    }

    // MARK: - How much

    @Test("A finished series counts its whole run")
    func completedCountsInFull() {
        // Finishing something and not ticking the last box is the ordinary
        // case. Counting it as zero makes the total absurd.
        let read = ReadingInsights.chaptersRead(in: [
            entry(1, .completed, read: nil, total: 200),
            entry(2, .reading, read: 30, total: 100)
        ])
        #expect(read == 230)
    }

    @Test("A manhwa chapter is not a novel chapter")
    func hoursVaryByFormat() {
        let manhwa = ReadingInsights.hoursRead(in: [
            entry(1, .reading, read: 100, total: 200, type: "manhwa")
        ])
        let novel = ReadingInsights.hoursRead(in: [
            entry(1, .reading, read: 100, total: 200, type: "novel")
        ])
        #expect(novel > manhwa * 2, "a prose chapter is a different sitting entirely")
    }

    // MARK: - Verdicts

    @Test("What you finish and what you abandon, by tag")
    func verdictsSplitByOutcome() {
        let murimTags = [tag(1, "Murim")]
        let haremTags = [tag(2, "Harem")]
        let rows = ReadingInsights.verdicts(in: [
            entry(1, .completed, rating: 90, tags: murimTags),
            entry(2, .completed, rating: 80, tags: murimTags),
            entry(3, .completed, tags: murimTags),
            entry(4, .dropped, tags: haremTags),
            entry(5, .dropped, tags: haremTags),
            entry(6, .dropped, tags: haremTags)
        ])

        let murim = rows.first { $0.name == "Murim" }
        let harem = rows.first { $0.name == "Harem" }
        #expect(murim?.completionRate == 1)
        #expect(harem?.completionRate == 0)
        #expect(murim?.rating == 4.25, "averaged over the two that were rated")
    }

    @Test("A tag on two series is a coincidence, not a verdict")
    func verdictsNeedAPattern() {
        let rows = ReadingInsights.verdicts(in: [
            entry(1, .completed, tags: [tag(1, "Cooking")]),
            entry(2, .completed, tags: [tag(1, "Cooking")])
        ])
        #expect(rows.isEmpty)
    }

    @Test("Things you never read say nothing about your taste")
    func verdictsIgnoreIntent() {
        // Plan-to-read is evidence of ambition, not of what someone finishes.
        let rows = ReadingInsights.verdicts(in: (1...5).map {
            entry($0, .planToRead, tags: [tag(1, "Isekai")])
        })
        #expect(rows.isEmpty)
    }

    @Test("Still-reading series have no completion rate yet")
    func undecidedHasNoRate() {
        // A shelf full of things in progress says nothing about whether they
        // will be finished, and a rate of zero would read as "you abandon this".
        let rows = ReadingInsights.verdicts(in: (1...4).map {
            entry($0, .reading, tags: [tag(1, "Regression")])
        })
        #expect(rows.first?.completionRate == nil)
    }

    @Test("The sample size is reported, not hidden")
    func sampleSizeIsHonest() {
        // A verdict drawn from 2 of 5 series is a different claim from one
        // drawn from all of them, and the reader cannot tell which they see.
        let sample = ReadingInsights.sampleSize(in: [
            entry(1, .completed, tags: [tag(1, "Murim")]),
            entry(2, .completed, tags: [tag(1, "Murim")]),
            entry(3, .completed),
            entry(4, .dropped),
            entry(5, .dropped)
        ])
        #expect(sample.seen == 2)
        #expect(sample.total == 5)
    }
}
