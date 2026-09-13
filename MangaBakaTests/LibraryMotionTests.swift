import Testing
import Foundation
@testable import MangaBaka

/// The pure decisions behind the Library area's motion: what fires a haptic,
/// what waits before arriving, what counts as "just finished". The SwiftUI
/// wiring these decisions feed (`.celebrates(on:)`, `.arrives(index:)`, the
/// drag gesture in `RatingSegments`) is verified on the simulator, not here —
/// see rule 10 of the motion brief.
@Suite("Library motion")
struct LibraryMotionTests {
    // MARK: - RatingSegments: pips crossed while dragging

    @Test("Dragging one pip over owes one tick")
    func onePipOneTick() {
        #expect(RatingSegments.pipsCrossed(from: 1, to: 2) == 1)
    }

    @Test("A fast drag across several pips owes one tick per pip, not one for the landing")
    func fastDragCountsEveryPip() {
        // A finger that crosses from "Any" straight to "9+" felt four
        // boundaries on the way, even though only one `onChanged` update may
        // have landed in that frame.
        #expect(RatingSegments.pipsCrossed(from: 0, to: 4) == 4)
    }

    @Test("Dragging back down still counts, direction does not matter")
    func draggingBackwardCounts() {
        #expect(RatingSegments.pipsCrossed(from: 4, to: 1) == 3)
    }

    @Test("No movement is no tick")
    func noMovementNoTick() {
        #expect(RatingSegments.pipsCrossed(from: 2, to: 2) == 0)
    }

    @Test("A position resolves to the pip it falls in, clamped to the ends")
    func indexResolvesAndClamps() {
        #expect(RatingSegments.index(atX: -50, width: 200, count: 5) == 0, "past the left edge")
        #expect(RatingSegments.index(atX: 250, width: 200, count: 5) == 4, "past the right edge")
        #expect(RatingSegments.index(atX: 100, width: 200, count: 5) == 2, "the middle pip")
    }

    // MARK: - LibraryControl: the one-shot completion checkmark

    /// Expected to fail before the fix with: no `shouldCelebrate` on
    /// `LibraryControlModel` at all.
    @Test("Reading to Completed celebrates")
    func readingToCompletedCelebrates() {
        #expect(LibraryControlModel.shouldCelebrate(old: .reading, new: .completed))
    }

    @Test("Completed to Completed does not celebrate twice")
    func alreadyCompletedDoesNotRecelebrate() {
        #expect(!LibraryControlModel.shouldCelebrate(old: .completed, new: .completed))
    }

    @Test("Leaving Completed does not celebrate")
    func leavingCompletedDoesNotCelebrate() {
        #expect(!LibraryControlModel.shouldCelebrate(old: .completed, new: .rereading))
    }

    /// The control's own first look at an entry — `load()` populating
    /// `entry` for the first time — is not the reader finishing something
    /// mid-session, even when what it finds is already Completed.
    @Test("The control's first look at an already-completed entry does not celebrate")
    func firstLoadOfCompletedDoesNotCelebrate() {
        #expect(!LibraryControlModel.shouldCelebrate(old: nil, new: .completed))
    }

    @Test("A state that was never known becoming known but not Completed does not celebrate")
    func firstLoadOfAnythingElseDoesNotCelebrate() {
        #expect(!LibraryControlModel.shouldCelebrate(old: nil, new: .reading))
    }

    // MARK: - LibraryList: arrival stagger caps on a very long list

    /// Gap: an uncapped stagger would make a 900-row library's last rows wait
    /// tens of seconds to arrive. `Motion.stagger` itself caps at 6 steps
    /// (Batch 0); this checks that a library-sized index actually hits that
    /// ceiling rather than a library-scale index quietly overflowing the
    /// calculation some other way.
    /// Expected to fail before the fix with: 40.5 (900 * 0.045), were the cap
    /// absent.
    @Test("A 900-row library's last row waits no longer than the cap")
    func stagerCapsOnALongLibrary() {
        let capped = Motion.stagger(6)
        #expect(Motion.stagger(899) == capped)
        #expect(Motion.stagger(6) == capped)
        #expect(Motion.stagger(0) == 0)
        #expect(Motion.stagger(3) < capped)
    }

    @Test("Stagger delay increases monotonically up to the cap")
    func staggerIsMonotonicBelowTheCap() {
        for index in 0..<6 {
            #expect(Motion.stagger(index) <= Motion.stagger(index + 1))
        }
    }

    // MARK: - PickBackUp: the progress bar's target value

    private func entryAndSeries(
        progressChapter: Double?, totalChapters: Double? = 100
    ) -> (LibraryEntry, Series) {
        let series = SeriesFactory.make(id: 1, totalChapters: totalChapters)
        let entry = LibraryEntry(
            id: 1, seriesId: 1, state: .reading, progressChapter: progressChapter,
            progressVolume: nil, rating: nil, note: nil, startDate: nil, finishDate: nil,
            numberOfRereads: nil, priority: nil, isPrivate: nil, readLink: nil,
            series: series
        )
        return (entry, series)
    }

    @Test("The bar's target is the read fraction of the total")
    func fractionIsReadOverTotal() {
        let (subject, series) = entryAndSeries(progressChapter: 25)
        #expect(PickBackUp.fraction(subject, series: series) == 0.25)
    }

    @Test("A reader past the recorded total clamps the bar at full, not over")
    func fractionClampsPastTheTotal() {
        let (subject, series) = entryAndSeries(progressChapter: 140)
        #expect(PickBackUp.fraction(subject, series: series) == 1)
    }

    @Test("No progress is no bar")
    func noProgressNoTarget() {
        let (subject, series) = entryAndSeries(progressChapter: nil)
        #expect(PickBackUp.fraction(subject, series: series) == nil)
    }

    @Test("A series with no chapter count is no bar either — there is no denominator")
    func noTotalNoTarget() {
        let (subject, series) = entryAndSeries(progressChapter: 12, totalChapters: nil)
        #expect(PickBackUp.fraction(subject, series: series) == nil)
    }
}
