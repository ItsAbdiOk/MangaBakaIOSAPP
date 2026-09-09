import Foundation
import Testing
@testable import MangaBaka

/// Covers used to be framed at each series' own reported dimensions, so a row
/// of them came out visibly ragged: different heights, titles on different
/// baselines. The API's ratio is per-scan and varies; the frame must not.
@Suite("Cover layout")
struct CoverLayoutTests {
    /// The premise of the bug, stated as a measurement rather than assumed.
    /// `Cover.sized` is a tidy 2:3 fixture and would have proved nothing;
    /// `Cover.realWide` is a cover the live API actually returned.
    @Test("A real cover's reported ratio is not the layout ratio")
    func reportedRatioDiffers() throws {
        let ratio = try #require(Cover.realWide.aspectRatio)
        #expect(ratio != Double(Metrics.coverAspect))
    }

    /// At the row's cover width the difference is 53 points — a third of the
    /// cover's height, not a rounding error.
    @Test("Framing by the reported ratio would change the height noticeably")
    func heightDifferenceIsVisible() throws {
        let width = Double(Metrics.coverRowWidth)
        let layoutHeight = width / Double(Metrics.coverAspect)
        let reportedHeight = width / (try #require(Cover.realWide.aspectRatio))
        #expect(abs(layoutHeight - reportedHeight) > 20)
    }

    /// The fix itself. A unit test cannot measure a SwiftUI frame, so this
    /// asserts the thing that actually regressed: the view reaching for the
    /// per-cover ratio when it sizes itself.
    @Test("CoverImage sizes its frame from the layout ratio, not the cover's",
          .enabled(if: SourceTree.isAvailable))
    func frameIgnoresReportedRatio() throws {
        let source = try SourceTree.read("MangaBaka/Features/Shared/CoverImage.swift")
        // The ratio may still be mentioned in a comment explaining why it is
        // not used, so this looks for the use, not the word.
        #expect(!source.contains("cover.aspectRatio ??"))
        #expect(source.contains(".frame(width: width, height: height)"))
    }
}
