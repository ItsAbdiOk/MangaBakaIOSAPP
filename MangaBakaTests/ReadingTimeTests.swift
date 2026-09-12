import Testing
import Foundation
@testable import MangaBaka

/// A control for each number here: the manga and manhwa constants are
/// checked against their own hand-computed hours (chapters × seconds ÷
/// 3600), not just against the label they produce.
@Suite("Reading time")
struct ReadingTimeTests {
    @Test("Manga hours: 100 chapters at 170s each")
    func mangaHours() {
        let hours = ReadingTime.hours(chapters: 100, type: "manga")
        #expect(hours != nil)
        #expect(abs((hours ?? 0) - (170.0 * 100 / 3600)) < 0.001)
    }

    @Test("Manhwa hours: 100 chapters at 214s each")
    func manhwaHours() {
        let hours = ReadingTime.hours(chapters: 100, type: "manhwa")
        #expect(hours != nil)
        #expect(abs((hours ?? 0) - (214.0 * 100 / 3600)) < 0.001)
    }

    @Test("An unknown type falls to the default seconds-per-chapter")
    func unknownTypeUsesDefault() {
        let hours = ReadingTime.hours(chapters: 100, type: "manhua")
        let expected = ReadingTime.defaultSecondsPerChapter * 100 / 3600
        #expect(hours != nil)
        #expect(abs((hours ?? 0) - expected) < 0.001)
    }

    @Test("Nil chapters produce no estimate")
    func nilChaptersIsNil() {
        #expect(ReadingTime.hours(chapters: nil, type: "manga") == nil)
    }

    @Test("Zero or negative chapters produce no estimate")
    func zeroChaptersIsNil() {
        #expect(ReadingTime.hours(chapters: 0, type: "manga") == nil)
        #expect(ReadingTime.hours(chapters: -5, type: "manga") == nil)
    }

    @Test("Type matching is case-insensitive")
    func caseInsensitiveType() {
        let mixed = ReadingTime.hours(chapters: 100, type: "Manhwa")
        let lower = ReadingTime.hours(chapters: 100, type: "manhwa")
        #expect(mixed == lower)
    }

    @Test("Under an hour renders as minutes")
    func labelUnderAnHour() {
        // 0.75h at 202s default => chapters = 0.75 * 3600 / 202
        let chapters = 0.75 * 3600 / 202
        #expect(ReadingTime.label(chapters: chapters, type: "unknown") == "≈ 45 min")
    }

    @Test("An hours figure rounds to the nearest whole hour")
    func labelRoundsHours() {
        // Manga, 100 chapters => 4.72h, rounds to 5.
        #expect(ReadingTime.label(chapters: 100, type: "manga") == "≈ 5 h")
    }

    @Test("A whole-hour figure stays in hours")
    func labelWholeHours() {
        let chapters = 14.0 * 3600 / 202
        #expect(ReadingTime.label(chapters: chapters, type: "unknown") == "≈ 14 h")
    }

    @Test("A day-scale figure renders in days of 8 reading hours")
    func labelDays() {
        let chapters = 32.0 * 3600 / 202
        #expect(ReadingTime.label(chapters: chapters, type: "unknown") == "≈ 4 days")
    }

    @Test("Nil hours produce no label")
    func labelNilWhenNoHours() {
        #expect(ReadingTime.label(chapters: nil, type: "manga") == nil)
    }
}
