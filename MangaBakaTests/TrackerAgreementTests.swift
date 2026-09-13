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

    /// `scored` used to come straight off a `Dictionary`, so a tie for
    /// highest or lowest was broken by hash order — the named tracker in
    /// "Readers disagree" could change between launches with the same three
    /// scores. Sorted by name first, the extreme picked among a tie is
    /// always the alphabetically-first name. Expected to fail intermittently
    /// before the fix, since a `Dictionary`'s iteration order is not fixed
    /// across runs.
    @Test("A tie for highest or lowest is broken by name, not hash order")
    func tiesAreBrokenDeterministically() {
        let source = [
            "kitsu": entry(90),
            "anilist": entry(90),
            "manga_updates": entry(50)
        ]
        let result = TrackerScores.agreement(source)
        #expect(result == .divisive(
            high: .init(name: "AniList", score: 90),
            low: .init(name: "MangaUpdates", score: 50)
        ))
    }
}

/// The verdict sentence names the threshold that decides it, so tuning one
/// without the other would make the sentence lie.
@Suite("Tracker agreement verdict text")
struct TrackerVerdictTextTests {
    /// "within 5 points" was a copy of `agreedSpread`, not a read of it, and
    /// `verdictText` was a private instance method with nothing to test it
    /// against. Before the fix this test does not compile — `verdictText`
    /// did not exist as a callable static function — and after the fix the
    /// value it prints is interpolated from `agreedSpread` rather than typed
    /// twice.
    @Test("The agreed verdict names the actual threshold, not a copy of it")
    func verdictNamesLiveThreshold() {
        #expect(TrackerScores.verdictText(.agreed) == "Every tracker agrees, within 5 points")
    }

    @Test("The divisive verdict names both extremes")
    func verdictNamesExtremes() {
        let text = TrackerScores.verdictText(.divisive(
            high: .init(name: "AniList", score: 84),
            low: .init(name: "MangaUpdates", score: 62)
        ))
        #expect(text == "Readers disagree: AniList 84, MangaUpdates 62")
    }

    @Test("No verdict is no line")
    func noVerdictIsNoLine() {
        #expect(TrackerScores.verdictText(nil) == nil)
    }
}
