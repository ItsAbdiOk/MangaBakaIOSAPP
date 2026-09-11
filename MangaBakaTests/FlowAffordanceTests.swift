import Foundation
import Testing
@testable import MangaBaka

/// What is left of the flow-affordance greps.
///
/// The rest moved to `MangaBakaUITests/FlowAffordanceUITests`, where they
/// press the button instead of checking that a file mentions it. The reason is
/// not theoretical: `AccessibilityTests` grepped `SeriesDetailView.swift` for a
/// chip's `minHeight` and had been matching `FlowChips`, a view nothing
/// presented, passing for weeks against code that never ran.
///
/// These two survive because they assert the ABSENCE of a route, and an
/// absence cannot be pressed. Both guard against a fix being undone by
/// reintroducing the thing it removed.
@Suite("Flow affordances that can only be read", .enabled(if: SourceTree.isAvailable))
struct FlowAffordanceTests {
    /// The "+" used to open the Search TAB, which keeps its query, its results
    /// and its pushed series page — so adding a second seed landed you back on
    /// the first seed's page. The sheet replaced it.
    ///
    /// The behaviour is tested in
    /// `FlowAffordanceUITests.testSeedPickerDoesNotReturnYouToYourLastSearch`.
    /// This asserts the old route is gone rather than merely unused, because a
    /// dormant tab-switching callback is how it would come back.
    @Test("The tab-switching route out of Mix is gone, not merely unused")
    func seedPickerHasNoTabRoute() throws {
        let mix = try SourceTree.read("MangaBaka/Features/Mix/MixView.swift")
        #expect(!mix.contains("onPickSeed"))
    }

    /// A page must not be poorer for the door the reader came in by.
    ///
    /// The merge itself is tested in `SeriesMergeTests`; what cannot be
    /// reached from a unit test is whether the detail page USES it, because
    /// `shown` is private and the view is not constructible without a database.
    @Test("The series page reads the merged series, not the copy it arrived with")
    func detailUsesTheFullSeries() throws {
        let detail = try SourceTree.read("MangaBaka/Features/Detail/SeriesDetailView.swift")
        #expect(detail.contains("filling(gapsFrom:"))
        #expect(
            detail.contains("if let description = shown.description"),
            "the synopsis is the field that was missing when opened from the stack"
        )
    }
}
