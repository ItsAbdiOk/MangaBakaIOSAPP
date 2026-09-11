import Testing
import Foundation
@testable import MangaBaka

/// The one surface that says MangaBaka is maintained by people.
///
/// Figures verified live on 2026-09-11: 304,108 active series (303,832 the
/// week before), 19,023 registered readers (17,536), 53,975,689.26 chapters
/// read (50,963,627.60).
@Suite("Community pulse")
struct CommunityPulseTests {
    private func pulse(
        series: Int = 304_108, seriesPrev: Int = 303_832,
        users: Int = 19_023, usersPrev: Int = 17_536,
        chapters: Double = 53_975_689.25981874, chaptersPrev: Double = 50_963_627.59869605
    ) -> CommunityPulse {
        CommunityPulse(
            activeSeriesCount: series, activeSeriesCountPrevWeek: seriesPrev,
            registeredUserCount: users, registeredUserCountPrevWeek: usersPrev,
            chaptersReadCount: chapters, chaptersReadCountPrevWeek: chaptersPrev
        )
    }

    @Test("The bare object decodes — there is no envelope around it")
    func decodesWithoutAnEnvelope() throws {
        // Two envelope shapes were already known: `data` for most endpoints,
        // `results` for recommendations. This is a third — the object itself.
        // Decoding it as either of the others fails outright.
        let json = Data("""
        {"active_series_count": 304108, "active_series_count_prev_week": 303832,
         "registered_user_count": 19023, "registered_user_count_prev_week": 17536,
         "chapters_read_count": 53975689.25981874,
         "chapters_read_count_prev_week": 50963627.59869605,
         "edits_last_7_days": 10065}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(CommunityPulse.self, from: json)

        #expect(decoded.activeSeriesCount == 304_108)
        #expect(decoded.registeredUserCount == 19_023)
    }

    @Test("Chapters lead, because they are the only figure about reading")
    func chaptersComeFirst() {
        #expect(pulse().figures.map(\.id) == ["chapters", "series", "readers"])
    }

    @Test("A fractional chapter count is rounded, and the change still adds up")
    func fractionsAreRounded() {
        // The API counts a part-read chapter as a fraction. Nobody wants to
        // see a quarter of a chapter, and a delta computed from the unrounded
        // values would not match the two numbers shown either side of it.
        let figure = pulse().figures.first
        #expect(figure?.value == 53_975_689.formatted())
        #expect(figure?.change == "+\((53_975_689 - 50_963_628).formatted()) this week")
    }

    @Test("A week that did not move says nothing")
    func flatWeekHasNoChange() {
        // "+0 this week" on a community page reads as a dead community.
        let flat = pulse(series: 100, seriesPrev: 100)
        let series = flat.figures.first { $0.id == "series" }
        #expect(series?.change == nil)
    }

    @Test("A week that went backwards says nothing either")
    func shrinkingWeekHasNoChange() {
        // Series get merged as duplicates, so the count can fall. "-40 this
        // week" invites a question the app cannot answer.
        let shrunk = pulse(series: 100, seriesPrev: 140)
        #expect(shrunk.figures.first { $0.id == "series" }?.change == nil)
    }

    @Test("The reader is placed inside the big number")
    func readerShareIsTheWholePoint() {
        // 53,975,689 says nothing on its own.
        #expect(pulse().readerShare(chaptersRead: 4_210) == "4,210 of them are yours")
    }

    @Test("A reader who has read nothing is not told they are nothing")
    func noShareWithoutReading() {
        #expect(pulse().readerShare(chaptersRead: 0) == nil)
    }
}
