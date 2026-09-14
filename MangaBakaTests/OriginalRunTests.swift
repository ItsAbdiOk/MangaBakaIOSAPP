import Foundation
import Testing
@testable import MangaBaka

/// Parsing `MangaUpdatesSeries.status` into `OriginalRun`.
///
/// Expected failure before this file existed: none of these compile — there
/// was no `OriginalRun` type at all, only `MangaUpdatesSeries.status: String?`
/// sitting unread by anything (`docs/sources/webtoon-episodes.md`, "What a
/// follow-up implementation would need", item 1).
@Suite("OriginalRun parsing")
struct OriginalRunTests {
    private func series(
        status: String?, editedAt: String? = nil
    ) -> MangaUpdatesSeries {
        MangaUpdatesSeries(
            seriesID: 1, categories: [], bayesianRating: nil, ratingVotes: nil, latestChapter: nil,
            status: status, licensed: nil, completed: nil,
            lastUpdated: editedAt.map { MangaUpdatesSeries.LastUpdated(asRFC3339: $0) }
        )
    }

    /// Tower of God, captured live 2026-09-14 (`docs/sources/
    /// webtoon-episodes.md`): ongoing, two counts, a season breakdown after
    /// it that must not be read as more chapters.
    @Test("Tower of God's real status string parses")
    func parsesOngoingWithVolumes() throws {
        let status = "652 Chapters (Ongoing)  \n18 Volumes (Ongoing)\n\nS1: 78 Chapters + Prologue  \n"
            + "S2: 337 Chapters + Prologue  \nS3: 235 Chapters  \n"
        let fixture = series(status: status, editedAt: "2026-08-07T18:28:36-07:00")
        let run = try #require(OriginalRun.parse(fixture))
        #expect(run.chapters == 652)
        #expect(run.volumes == 18)
        #expect(run.isOngoing)
        let edited = try #require(run.editedAt)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let components = calendar.dateComponents([.year, .month, .day], from: edited)
        #expect(components.year == 2026)
        #expect(components.month == 8)
        // 18:28:36 -07:00 is 01:28:36 UTC the next day.
        #expect(components.day == 8)
    }

    /// Solo Leveling, same source: complete, a "+ Prologue" chapter suffix
    /// this pattern has to tolerate without reading "Prologue" as a digit.
    @Test("Solo Leveling's real status string parses as complete")
    func parsesCompleteWithPrologueSuffix() throws {
        let status = "200 Chapters + Prologue (Complete)  \n15 Volumes (Complete)  \n"
        let run = try #require(OriginalRun.parse(series(status: status)))
        #expect(run.chapters == 200)
        #expect(run.volumes == 15)
        #expect(!run.isOngoing)
        #expect(run.editedAt == nil)
    }

    /// The malformed case named in the brief: a bare state word, no leading
    /// chapter count. Must not be read as "0 chapters" — that is a real
    /// number this app would then show as fact.
    @Test("A status with no leading chapter count is nil, not zero chapters")
    func noLeadingNumberIsNil() {
        #expect(OriginalRun.parse(series(status: "Ongoing")) == nil)
        #expect(OriginalRun.parse(series(status: "Some Series (Ongoing)")) == nil)
    }

    /// A status carrying only the volumes line and no chapters line at all —
    /// `chapters` is required, non-optional, so this must be nil rather than
    /// a run with a fabricated chapter count.
    @Test("A status with only a volumes line is nil")
    func onlyVolumesIsNil() {
        #expect(OriginalRun.parse(series(status: "18 Volumes (Ongoing)\n")) == nil)
    }

    @Test("A nil status is nil")
    func nilStatusIsNil() {
        #expect(OriginalRun.parse(series(status: nil)) == nil)
    }

    // MARK: - summaryLine

    @Test("The summary line names the language, state and edit date")
    func summaryLineWithEditDate() throws {
        let run = OriginalRun(
            chapters: 652, volumes: 18, isOngoing: true,
            editedAt: Date(timeIntervalSince1970: 1_754_000_000) // 2025-08-01, arbitrary
        )
        let line = run.summaryLine(language: "Korean")
        #expect(line.hasPrefix("≈652 in Korean · ongoing · MangaUpdates, edited"))
    }

    @Test("A nil language folds to 'the original', a nil editedAt drops the date")
    func summaryLineFallbacks() {
        let run = OriginalRun(chapters: 200, volumes: nil, isOngoing: false, editedAt: nil)
        #expect(run.summaryLine(language: nil) == "≈200 in the original · complete · MangaUpdates")
    }
}

/// `OriginalLanguageName` — the small helper the brief asked for since no
/// existing one maps a language code to its display word (`SeriesDetailView
/// +Editions.threeLetter` maps the same codes to ISO 639-2/B instead).
@Suite("OriginalLanguageName")
struct OriginalLanguageNameTests {
    @Test("The three codes Series.impliedLanguage can produce are named")
    func namesKnownCodes() {
        #expect(OriginalLanguageName.name(for: "ja") == "Japanese")
        #expect(OriginalLanguageName.name(for: "ko") == "Korean")
        #expect(OriginalLanguageName.name(for: "zh") == "Chinese")
        // Case-insensitive: MangaBaka's own casing of a language tag is not
        // guaranteed lowercase everywhere it is read from.
        #expect(OriginalLanguageName.name(for: "KO") == "Korean")
    }

    @Test("An unmapped or nil code is nil, not a guess")
    func unmappedCodeIsNil() {
        #expect(OriginalLanguageName.name(for: "en") == nil)
        #expect(OriginalLanguageName.name(for: nil) == nil)
    }
}
