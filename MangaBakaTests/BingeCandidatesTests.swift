import Foundation
import Testing
@testable import MangaBaka

/// The "Binge a season" rule (Abdi, 2026-09-15): reading / rereading /
/// paused, untouched for 30 days, and either a season finished past the
/// reader's, a newer season started, or ≥100 chapters since they stopped.
@Suite("Binge a season")
struct BingeCandidatesTests {
    private let now = Date(timeIntervalSince1970: 1_757_000_000)

    private func entry(
        id: Int, state: LibraryEntry.State = .reading, progress: Double? = 10, total: Double? = nil
    ) -> LibraryEntry {
        LibraryEntry(
            id: id, seriesId: id, state: state, progressChapter: progress,
            progressVolume: nil, rating: nil, note: nil, startDate: nil,
            finishDate: nil, numberOfRereads: nil, priority: nil, isPrivate: nil,
            readLink: nil,
            series: SeriesFactory.make(id: id, title: "S\(id)", totalChapters: total)
        )
    }

    private func episode(_ number: Int, season: Int?, finale: Bool = false) -> ReleaseEntry {
        ReleaseEntry(
            title: finale ? "[Season \(season ?? 0)] Ep. \(number) (Season Finale)" : "Ep. \(number)",
            published: now.addingTimeInterval(Double(number - 100) * 86_400), number: number, season: season
        )
    }

    @Test("Control — an untouched reading entry with no signal is not a candidate")
    func control() {
        let found = BingeCandidates.find(in: [entry(id: 1, total: 50)], feeds: [:], lastOpened: [:], now: now)
        #expect(found.isEmpty)
    }

    @Test("Tier 3: a hundred chapters since the reader stopped, in every forgotten state")
    func chaptersWaiting() {
        let entries = [
            entry(id: 1, state: .reading, progress: 20, total: 120),
            entry(id: 2, state: .paused, progress: 0, total: 250),
            entry(id: 3, state: .rereading, progress: 300, total: 401),
            entry(id: 4, state: .dropped, progress: 0, total: 900),
            entry(id: 5, state: .planToRead, progress: nil, total: 900),
            entry(id: 6, state: .reading, progress: 21, total: 120)
        ]
        let found = BingeCandidates.find(in: entries, feeds: [:], lastOpened: [:], now: now)
        #expect(found.map(\.id) == [2, 3, 1], "most waiting first; 6 is one chapter short; 4 and 5 are out")
        #expect(found.first?.reason == .chaptersWaiting(250))
        #expect(found.first?.reason.line == "250 chapters since you stopped")
    }

    @Test("A series opened in the last thirty days is being read, not forgotten")
    func recentlyOpenedIsSkipped() {
        let entries = [entry(id: 1, progress: 0, total: 300)]
        let recent = BingeCandidates.find(
            in: entries, feeds: [:], lastOpened: [1: now.addingTimeInterval(-5 * 86_400)], now: now
        )
        #expect(recent.isEmpty)
        let old = BingeCandidates.find(
            in: entries, feeds: [:], lastOpened: [1: now.addingTimeInterval(-40 * 86_400)], now: now
        )
        #expect(old.count == 1)
    }

    @Test("Tier 1: a season that ended past the reader's own reads as complete, with the count")
    func seasonComplete() {
        let feed = ReleaseFeed(
            title: "F",
            entries: [episode(10, season: 1), episode(11, season: 2), episode(12, season: 2),
                      episode(13, season: 2, finale: true)],
            source: .webtoons
        )
        let found = BingeCandidates.find(
            in: [entry(id: 1, progress: 10, total: 13)], feeds: [1: feed], lastOpened: [:], now: now
        )
        #expect(found.first?.reason == .seasonComplete(season: 2, waiting: 3))
        #expect(found.first?.reason.line == "Season 2 is complete · 3 to read")
    }

    @Test("Tier 1: a newer season that has started but not ended says so")
    func newSeason() {
        let feed = ReleaseFeed(
            title: "F", entries: [episode(10, season: 1), episode(11, season: 2)], source: .webtoons
        )
        let found = BingeCandidates.find(
            in: [entry(id: 1, progress: 10)], feeds: [1: feed], lastOpened: [:], now: now
        )
        #expect(found.first?.reason == .newSeason(season: 2))
    }

    @Test("A feed without season numbers falls through to the chapter count")
    func feedWithoutSeasonsFallsThrough() {
        let feed = ReleaseFeed(title: "F", entries: [episode(200, season: nil)], source: .webtoons)
        let found = BingeCandidates.find(
            in: [entry(id: 1, progress: 10, total: 200)], feeds: [1: feed], lastOpened: [:], now: now
        )
        #expect(found.first?.reason == .chaptersWaiting(190))
    }

    @Test("The reader who is on the latest season has nothing to binge")
    func upToDate() {
        let feed = ReleaseFeed(
            title: "F", entries: [episode(10, season: 2), episode(11, season: 2)], source: .webtoons
        )
        let found = BingeCandidates.find(
            in: [entry(id: 1, progress: 11)], feeds: [1: feed], lastOpened: [:], now: now
        )
        #expect(found.isEmpty)
    }
}
