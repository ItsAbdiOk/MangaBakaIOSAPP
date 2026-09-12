import Foundation
import Testing
@testable import MangaBaka

/// Comparing a translation against its original. See `TranslationGap`.
///
/// The English edition leads the section; Korean is mentioned only when it says
/// something English cannot. The case that matters is the original stopping
/// while the translation is still running — nothing on the English side can
/// reveal that, and it is why the Korean feed is read at all.
@Suite("Translation gap")
struct TranslationGapTests {
    private let now = Date(timeIntervalSince1970: 1_757_000_000)

    private func daysAgo(_ days: Int) -> Date {
        now.addingTimeInterval(-Double(days) * 86_400)
    }

    /// A weekly original, which is what makes "quiet for a month" mean anything.
    private func weekly() -> Cadence? {
        Cadence.estimate(from: (0...9).map { daysAgo($0 * 7) })
    }

    /// The control: the helper above really does produce a weekly rhythm, so a
    /// failure below is about the comparison and not the fixture.
    @Test("Control: the original's cadence reads as weekly")
    func controlCadence() throws {
        let cadence = try #require(weekly())
        #expect(cadence.medianGapDays == 7)
    }

    @Test("Nothing is said when the original is level or behind")
    func levelSaysNothing() {
        #expect(TranslationGap.between(
            translated: 112, original: (112, daysAgo(7)), originalCadence: weekly(), now: now
        ) == .none)
        #expect(TranslationGap.between(
            translated: 140, original: (112, daysAgo(7)), originalCadence: weekly(), now: now
        ) == .none)
    }

    @Test("Nothing is said when there is no original to compare against")
    func missingDataSaysNothing() {
        #expect(TranslationGap.between(
            translated: 112, original: nil, originalCadence: weekly(), now: now
        ) == .none)
        #expect(TranslationGap.between(
            translated: nil, original: (140, daysAgo(7)), originalCadence: weekly(), now: now
        ) == .none)
    }

    /// The ordinary case. Every translation lags, so this is information, not
    /// an alarm.
    @Test("An original that is ahead and still moving is simply ahead")
    func aheadAndRunning() {
        #expect(TranslationGap.between(
            translated: 112, original: (140, daysAgo(7)), originalCadence: weekly(), now: now
        ) == .ahead(episodes: 28))
    }

    /// The case worth reading the Korean feed for: the source has stopped, the
    /// English edition is still shipping, and the reader is 28 episodes from
    /// finding out on their own.
    @Test("A weekly original silent for months is paused, not merely ahead")
    func originalPaused() {
        let gap = TranslationGap.between(
            translated: 112, original: (140, daysAgo(90)), originalCadence: weekly(), now: now
        )
        #expect(gap == .originalPaused(since: daysAgo(90), episodesAhead: 28))
    }

    /// The boundary, stated in the original's own gaps rather than in days: at
    /// three weeks a weekly series has missed three releases exactly, which is
    /// the threshold, and just under it is still only "ahead".
    @Test("Pausing is measured in the original's own gaps, not the calendar")
    func thresholdIsRelative() {
        func gapAt(_ days: Int) -> TranslationGap {
            TranslationGap.between(
                translated: 112, original: (140, daysAgo(days)),
                originalCadence: weekly(), now: now
            )
        }
        #expect(gapAt(20) == .ahead(episodes: 28))
        #expect(gapAt(22) == .originalPaused(since: daysAgo(22), episodesAhead: 28))
    }

    /// Without a measured rhythm, silence means nothing: six quiet weeks is a
    /// hiatus for a weekly series and unremarkable for an irregular one, so the
    /// app declines to call it either way.
    @Test("Silence is never called a pause without a rhythm to judge it by")
    func noCadenceNeverPauses() {
        #expect(TranslationGap.between(
            translated: 112, original: (140, daysAgo(400)), originalCadence: nil, now: now
        ) == .ahead(episodes: 28))
    }

    @Test("Only none is empty")
    func emptiness() {
        #expect(TranslationGap.none.isEmpty)
        #expect(!TranslationGap.ahead(episodes: 1).isEmpty)
        #expect(!TranslationGap.originalPaused(since: now, episodesAhead: 1).isEmpty)
    }
}
