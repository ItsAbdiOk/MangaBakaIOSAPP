import Foundation
import Testing
@testable import MangaBaka

/// The mockup's five-segment minimum-rating control, which replaced a Stepper.
/// The Stepper needed nine taps to reach 9+ from Any on a control whose whole
/// useful range is five values, and showed none of them until you walked there.
@Suite("Minimum rating segments")
@MainActor
struct RatingSegmentsTests {
    /// "Any" is nil, never zero. `minimum_rating=0` is a filter that matches
    /// everything while still narrowing the query — a control that does
    /// nothing, which is exactly the bug that made "Surprise me" dead.
    @Test("Any is the absence of a filter, not a rating of zero")
    func anyIsNil() {
        #expect(RatingSegments.steps.first == .some(nil))
        #expect(!RatingSegments.steps.contains(.some(0)))
    }

    /// The API expresses rating 0-100 throughout, so a segment reading "8+"
    /// has to send 80. Sending 8 would return almost the whole catalogue.
    @Test("Segments carry the API's own scale")
    func apiScale() {
        #expect(RatingSegments.steps == [nil, 60, 70, 80, 90])
    }

    @Test(
        "Labels read as ratings, not as API values",
        arguments: [(nil, "Any"), (60, "6+"), (70, "7+"), (80, "8+"), (90, "9+")] as [(Int?, String)]
    )
    func labels(_ step: Int?, _ expected: String) {
        #expect(RatingSegments.label(for: step) == expected)
    }
}

/// One control for one API parameter. Mix used to offer Any/7/8/9 as capsules
/// while the search sheet offered a stepper — a different shape and a different
/// set of values for `minimum_rating` on the same API.
@Suite("The rating control is shared", .enabled(if: SourceTree.isAvailable))
struct RatingSegmentsReachabilityTests {
    @Test("Search filters and Mix use the same control")
    func sharedControl() throws {
        for path in [
            "MangaBaka/Features/Search/FilterSheet.swift",
            // The filter strip moved to its own file when Mix gained the
            // save-a-lens control and crossed the body-length ceiling.
            "MangaBaka/Features/Mix/MixFilterStrip.swift"
        ] {
            #expect(try SourceTree.read(path).contains("RatingSegments(minimum:"))
        }
    }

    /// The Stepper is what this replaced; leaving one behind would put two
    /// controls for the same value back in the app.
    @Test("No Stepper survives for rating")
    func noStepperLeft() throws {
        let sheet = try SourceTree.read("MangaBaka/Features/Search/FilterSheet.swift")
        #expect(!sheet.contains("Stepper("))
    }
}
