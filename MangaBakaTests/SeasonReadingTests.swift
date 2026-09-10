import Testing
import Foundation
@testable import MangaBaka

/// Which season a series is in, where it has seasons at all.
///
/// MangaUpdates puts one number in a release's `volume` field and uses it for
/// two different ideas. Checked against the live endpoint on 2026-09-10: Tower
/// of God's latest releases are `v.3 c.235`, which is season three; Solo
/// Leveling's are `v.1`, which is a print volume of a series that never had
/// seasons. Nothing in the response says which is which.
@Suite("Seasons, where there are any")
struct SeasonReadingTests {
    private func sample(volume: Int, chapter: Double, day: Int) -> SeasonReading.Sample {
        SeasonReading.Sample(
            volume: volume,
            chapter: chapter,
            date: Date(timeIntervalSince1970: TimeInterval(day) * 86_400)
        )
    }

    @Test("Chapters that restart at a new volume are seasons")
    func restartsAreSeasons() {
        // Tower of God's shape: each season starts again from a low number.
        let releases = [
            sample(volume: 1, chapter: 78, day: 1),
            sample(volume: 1, chapter: 79, day: 8),
            sample(volume: 2, chapter: 3, day: 15),
            sample(volume: 2, chapter: 4, day: 22)
        ]
        #expect(SeasonReading.hasSeasons(releases))
        #expect(SeasonReading.currentSeason(releases) == 2)
    }

    @Test("Chapters that keep counting up are print volumes")
    func continuousNumberingIsNotSeasons() {
        // A series collected into volumes: chapter numbers run straight
        // through. Telling this reader they are on "season 3" would be wrong.
        let releases = [
            sample(volume: 1, chapter: 1, day: 1),
            sample(volume: 2, chapter: 12, day: 8),
            sample(volume: 3, chapter: 25, day: 15)
        ]
        #expect(!SeasonReading.hasSeasons(releases))
        #expect(SeasonReading.currentSeason(releases) == nil)
    }

    @Test("A print volume that starts partway down is not a new season")
    func volumeSplitsAreNotSeasons() {
        // The case the old threshold got wrong. A print volume ending at
        // chapter 20 followed by one starting at chapter 9 — an overlapping
        // or mis-tagged collected edition — satisfied "less than half of the
        // previous highest" and was announced as season 2. A season starts
        // again from the beginning; chapter 9 is not the beginning.
        let releases = [
            sample(volume: 1, chapter: 18, day: 1),
            sample(volume: 1, chapter: 20, day: 8),
            sample(volume: 2, chapter: 9, day: 15),
            sample(volume: 2, chapter: 11, day: 22)
        ]
        #expect(!SeasonReading.hasSeasons(releases))
        #expect(SeasonReading.currentSeason(releases) == nil)
    }

    @Test("A short run that restarts is not enough to call it a season")
    func shortRunsAreNotSeasons() {
        // Four chapters then a restart is far more likely to be a mis-tagged
        // volume field than a series that ran a season and came back.
        let releases = [
            sample(volume: 1, chapter: 4, day: 1),
            sample(volume: 2, chapter: 1, day: 8)
        ]
        #expect(!SeasonReading.hasSeasons(releases))
    }

    @Test("One volume is never a season")
    func singleVolumeIsNothing() {
        // Solo Leveling's shape: everything tagged v.1, no seasons at all.
        let releases = (1...5).map { sample(volume: 1, chapter: Double($0 * 10), day: $0) }
        #expect(!SeasonReading.hasSeasons(releases))
    }

    @Test("A straggler from an old season does not roll the season back")
    func newestReleaseWins() {
        // A late-posted chapter of season one should not make the app say the
        // series is back on season one.
        let releases = [
            sample(volume: 1, chapter: 80, day: 1),
            sample(volume: 2, chapter: 5, day: 20),
            sample(volume: 1, chapter: 81, day: 25)
        ]
        #expect(SeasonReading.hasSeasons(releases))
        #expect(SeasonReading.currentSeason(releases) == 1, "the newest release is what it says")
    }

    @Test("With no releases there is nothing to say")
    func emptyIsSilent() {
        #expect(SeasonReading.describe([]) == nil)
        #expect(!SeasonReading.hasSeasons([]))
    }

    @Test("A series without seasons is described by chapter alone")
    func describesWithoutASeason() {
        let releases = [
            sample(volume: 1, chapter: 10, day: 1),
            sample(volume: 2, chapter: 22, day: 8)
        ]
        #expect(SeasonReading.describe(releases) == "Chapter 22")
    }

    @Test("A series with seasons says which one")
    func describesWithASeason() {
        let releases = [
            sample(volume: 1, chapter: 90, day: 1),
            sample(volume: 2, chapter: 4, day: 8)
        ]
        #expect(SeasonReading.describe(releases) == "Season 2 · chapter 4")
    }
}

/// Turning a MangaUpdates release row into the two numbers this needs.
@Suite("Release rows become samples")
struct ReleaseSampleTests {
    private func release(
        volume: String?,
        chapter: String?,
        date: String?
    ) throws -> MangaUpdatesClient.Release {
        try JSONDecoder.seasonTests.decode(
            MangaUpdatesClient.Release.self,
            from: Data("""
            {"volume": \(volume.map { "\"\($0)\"" } ?? "null"),
             "chapter": \(chapter.map { "\"\($0)\"" } ?? "null"),
             "release_date": \(date.map { "\"\($0)\"" } ?? "null")}
            """.utf8)
        )
    }

    @Test("A range takes the chapter it starts at")
    func rangesUseTheFirstNumber() throws {
        // "57-58" is one release of two chapters; the first is where it sits.
        let sample = try release(volume: "2", chapter: "57-58", date: "2026-09-01").sample
        #expect(sample?.chapter == 57)
    }

    @Test("Decorated chapter numbers still parse")
    func decorationIsIgnored() throws {
        let sample = try release(volume: "3", chapter: "c.12 (end)", date: "2026-09-01").sample
        #expect(sample?.chapter == 12)
        #expect(sample?.volume == 3)
    }

    @Test("A release missing either number is not a sample")
    func incompleteRowsAreDropped() throws {
        // Most releases have no volume at all — Eleceed and Nano Machine send
        // none — and a sample without one says nothing about seasons.
        #expect(try release(volume: nil, chapter: "401", date: "2026-09-01").sample == nil)
        #expect(try release(volume: "", chapter: "401", date: "2026-09-01").sample == nil)
        #expect(try release(volume: "2", chapter: nil, date: "2026-09-01").sample == nil)
        #expect(try release(volume: "2", chapter: "12", date: nil).sample == nil)
    }
}

extension JSONDecoder {
    static var seasonTests: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
