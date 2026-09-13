import Foundation
import Testing
@testable import MangaBaka

/// The drag gesture's commit-threshold haptic: a latch, not a level, so
/// holding a drag past the line does not buzz on every frame.
@Suite("Stack gesture threshold latch")
struct StackGestureThresholdTests {
    @Test("Crossing the threshold ticks")
    func ticksOnCross() {
        #expect(StackGesture.crossedThreshold(previous: 50, current: 95, threshold: 92))
    }

    /// Expected to fail with the naive `abs(current) >= threshold` check
    /// this replaces: that reads true on every one of these frames, which is
    /// exactly the buzz-on-every-frame this latch exists to prevent.
    @Test("Holding past the threshold does not tick again")
    func doesNotRepeatWhileHeld() {
        #expect(!StackGesture.crossedThreshold(previous: 95, current: 96, threshold: 92))
        #expect(!StackGesture.crossedThreshold(previous: 96, current: 120, threshold: 92))
    }

    @Test("Dragging back under the line does not itself tick")
    func returningBelowDoesNotTick() {
        #expect(!StackGesture.crossedThreshold(previous: 96, current: 40, threshold: 92))
    }

    @Test("Re-crossing after returning below ticks again")
    func recrossingTicksAgain() {
        #expect(StackGesture.crossedThreshold(previous: 40, current: 95, threshold: 92))
    }

    @Test("A leftward (negative) drag crosses in absolute value")
    func negativeDirectionCrosses() {
        #expect(StackGesture.crossedThreshold(previous: -50, current: -95, threshold: 92))
    }

    @Test("Never having reached the threshold does not tick")
    func neverReachingDoesNotTick() {
        #expect(!StackGesture.crossedThreshold(previous: 10, current: 40, threshold: 92))
    }
}

/// The header's streak ring: how many of today's reactions have landed.
@Suite("Stack today's progress")
@MainActor
struct StackTodayProgressTests {
    private func makeShelf(clock: any Clock = SystemClock()) throws -> ShelfStore {
        ShelfStore(database: try AppDatabase.inMemory(), clock: clock)
    }

    /// Two series so a second reaction has something left to react to —
    /// `TwoCardRepository` keeps returning both, and `StackModel` filters
    /// out whichever one is already reacted to.
    private final class TwoCardRepository: StubRepositoryBase, @unchecked Sendable {
        override func feed(_ feed: FeedKind, forceRefresh: Bool) async -> FeedResult {
            FeedResult(
                series: [SeriesFactory.make(id: 1, title: "One"), SeriesFactory.make(id: 2, title: "Two")],
                origin: .network
            )
        }
    }

    /// `countToday` is the pure half of `todayProgress`: given raw
    /// timestamps and a fixed "now", it needs no database at all.
    ///
    /// Expected to fail with a naive rolling-24h check in place of calendar
    /// bucketing: at 10am today, a reaction from yesterday at 11pm is 11
    /// hours old — inside a 24h window, but not "today" on the calendar.
    @Test("countToday resets at local midnight, not on a rolling window")
    func countTodayResetsAtLocalMidnight() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 10)))
        let lateLastNight = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 12, hour: 23))
        )
        let earlierToday = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 1))
        )

        #expect(StackModel.countToday([lateLastNight], now: now, calendar: calendar) == 0)
        #expect(StackModel.countToday([earlierToday], now: now, calendar: calendar) == 1)
        #expect(StackModel.countToday([lateLastNight, earlierToday], now: now, calendar: calendar) == 1)
    }

    @Test("An empty history counts as nothing answered today")
    func emptyHistoryCountsAsZero() {
        #expect(StackModel.countToday([], now: Date()) == 0)
    }

    /// Integration half: every reaction — saved or skipped — moves the ring,
    /// via `ShelfStore.reactionTimestamps()` written by `record`.
    @Test("todayAnswered increments once per reaction, saved or skipped")
    func answeredCountsEachReaction() async throws {
        let shelf = try makeShelf()
        let model = StackModel(repository: TwoCardRepository(), shelf: shelf)
        await model.loadIfNeeded()
        #expect(model.todayProgress.answered == 0)

        await model.react(.saved)
        #expect(model.todayProgress.answered == 1)

        await model.react(.skipped)
        #expect(model.todayProgress.answered == 2)
    }

    @Test("dealt is the daily goal, not a literal count of cards shown")
    func dealtIsTheDailyGoal() async throws {
        let model = StackModel(repository: TwoCardRepository(), shelf: try makeShelf())
        await model.loadIfNeeded()
        #expect(model.todayProgress.dealt == StackModel.dailyGoal)
    }

    /// Resetting the stack clears the shelf, so the streak resets with it —
    /// otherwise the ring would keep counting reactions the reset just threw
    /// away, unlike every other number `resetStack` zeroes.
    @Test("Resetting the stack zeroes today's progress")
    func resetZeroesProgress() async throws {
        let shelf = try makeShelf()
        let model = StackModel(repository: TwoCardRepository(), shelf: shelf)
        await model.loadIfNeeded()
        await model.react(.saved)
        #expect(model.todayProgress.answered == 1)

        await model.resetStack()
        #expect(model.todayProgress.answered == 0)
    }
}
