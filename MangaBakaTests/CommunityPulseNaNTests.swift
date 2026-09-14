import Foundation
import Testing
@testable import MangaBaka

/// Item 9 (wire review, `docs/reviews/full/wire.md` finding 12, 2026-09-14):
/// `Int(current - previous)` at `CommunityPulse.swift:70` applied no guard to
/// a `Double` difference, unlike the `Int(wholeOrClamped: current)` call two
/// lines below it — the same struct's own comment (`CommunityPulse.swift:14-16`)
/// records that this API has sent a fractional `Double` for a field the spec
/// calls `number`, and `Int(_:)` traps outside roughly ±9.2×10¹⁸ or on NaN.
/// `App/RootView+Session.swift:54` has the same `Int(someDouble)` shape and is
/// a separate lane's file — not touched here.
@Suite("Community pulse — a NaN figure does not crash")
struct CommunityPulseNaNTests {
    /// Before the fix, this traps rather than failing an assertion:
    /// `Int(Double.nan)` is a Swift runtime precondition failure ("Fatal
    /// error: NaN is not representable as an Int"), raised from
    /// `CommunityPulse.swift:70` inside `figures`, before `#expect` ever
    /// gets a chance to run. That is the "traps today" the work list names.
    /// After the fix, `Int(wholeOrClamped:)` (`Int+Clamped.swift`) maps NaN
    /// to `0` — the same rule already applied to `current` itself — so the
    /// figure renders as an unreadable-but-harmless zero-change row instead
    /// of taking down the whole community pulse card.
    @Test("A NaN active-series count renders as zero change, not a crash")
    func nanActiveSeriesCountDoesNotTrap() {
        let pulse = CommunityPulse(
            activeSeriesCount: .nan,
            activeSeriesCountPrevWeek: 303_832,
            registeredUserCount: 19_023,
            registeredUserCountPrevWeek: 17_536,
            chaptersReadCount: 53_975_689.25981874,
            chaptersReadCountPrevWeek: 50_963_627.59869605
        )
        let series = pulse.figures.first { $0.id == "series" }
        #expect(series?.value == "0")
        #expect(series?.change == nil)
    }

    /// Same hazard, the other direction: a previous-week figure that is NaN
    /// while the current one is ordinary. `current - previous` is NaN either
    /// way `Int` sees it.
    @Test("A NaN previous-week count renders as zero change, not a crash")
    func nanPreviousWeekCountDoesNotTrap() {
        let pulse = CommunityPulse(
            activeSeriesCount: 304_108,
            activeSeriesCountPrevWeek: .nan,
            registeredUserCount: 19_023,
            registeredUserCountPrevWeek: 17_536,
            chaptersReadCount: 53_975_689.25981874,
            chaptersReadCountPrevWeek: 50_963_627.59869605
        )
        let series = pulse.figures.first { $0.id == "series" }
        #expect(series?.value == "304,108")
        #expect(series?.change == nil)
    }
}
