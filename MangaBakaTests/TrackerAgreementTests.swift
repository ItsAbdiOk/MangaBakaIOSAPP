import Testing
@testable import MangaBaka

/// The "divisive vs. agreed" verdict under `TrackerScores`, ported from a
/// sibling project's spread thresholds (GUESS: not derived from this app's
/// own data — see TrackerScores.swift).
@Suite("Tracker agreement")
struct TrackerAgreementTests {
    private func entry(_ ratingNormalized: Double?) -> Series.TrackerEntry {
        Series.TrackerEntry(id: "id", rating: nil, ratingNormalized: ratingNormalized)
    }

    @Test("A wide spread across three trackers names the highest and lowest")
    func wideSpreadIsDivisive() {
        let source = [
            "anilist": entry(84),
            "manga_updates": entry(62),
            "kitsu": entry(70)
        ]
        let result = TrackerScores.agreement(source)
        #expect(result == .divisive(
            high: .init(name: "AniList", score: 84),
            low: .init(name: "MangaUpdates", score: 62)
        ))
    }

    @Test("A narrow spread across three trackers reads as agreement")
    func narrowSpreadIsAgreed() {
        let source = [
            "anilist": entry(71),
            "manga_updates": entry(73),
            "kitsu": entry(75)
        ]
        #expect(TrackerScores.agreement(source) == .agreed)
    }

    @Test("Two scored trackers is too few to call either way")
    func tooFewSourcesIsNil() {
        let source = [
            "anilist": entry(90),
            "manga_updates": entry(50)
        ]
        #expect(TrackerScores.agreement(source) == nil)
    }

    @Test("A spread that clears neither threshold says nothing")
    func middlingSpreadIsNil() {
        let source = [
            "anilist": entry(70),
            "manga_updates": entry(60),
            "kitsu": entry(65)
        ]
        #expect(TrackerScores.agreement(source) == nil)
    }

    @Test("An unrated tracker doesn't count toward the source total")
    func unratedEntryIsIgnored() {
        let source = [
            "anilist": entry(84),
            "manga_updates": entry(62),
            "kitsu": entry(nil)
        ]
        #expect(TrackerScores.agreement(source) == nil)
    }
}
