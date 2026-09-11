import Testing
import SwiftUI
@testable import MangaBaka

/// Honouring "Reduce Motion".
///
/// Fifteen surfaces animated and one asked whether the reader wanted motion.
/// For someone who turns the setting on it is usually not about taste — motion
/// on a screen can cause real nausea — so an app that honours it in one place
/// out of fifteen has not honoured it.
@Suite("Reduce Motion")
@MainActor
struct MotionTests {
    @Test("With the setting on, there is no animation at all")
    func reducedMeansNone() {
        // Not a shorter animation. Reduce Motion asks for no movement, not for
        // quick movement; the state change still happens, it just happens at
        // once.
        #expect(Motion.reduced(.easeOut(duration: 0.22), isReduced: true) == nil)
        #expect(Motion.reduced(.snappy(duration: 0.2), isReduced: true) == nil)
    }

    @Test("With the setting off, the animation is untouched")
    func notReducedPassesThrough() {
        let animation = Animation.easeOut(duration: 0.22)
        #expect(Motion.reduced(animation, isReduced: false) == animation)
    }

    @Test("Nothing in, nothing out")
    func nilStaysNil() {
        #expect(Motion.reduced(nil, isReduced: false) == nil)
    }
}

/// The system flag itself, read the way the app reads it.
///
/// Separated from the pure decision above because it depends on the device's
/// own accessibility settings. Run with Reduce Motion forced on:
///
///   xcrun simctl spawn <device> defaults write com.apple.Accessibility \
///     ReduceMotionEnabled -bool true
///
/// It asserts nothing about which way the flag points — a test that demanded
/// one answer would fail on whichever machine had the opposite setting. It
/// asserts that `reduced` agrees with the flag, which is the actual contract.
@Suite("Reduce Motion, as the device reports it")
@MainActor
struct MotionSystemFlagTests {
    @Test("The default follows the system setting")
    func defaultFollowsTheSystem() {
        let animation = Animation.easeOut(duration: 0.22)
        if Motion.isReduced {
            #expect(Motion.reduced(animation) == nil)
        } else {
            #expect(Motion.reduced(animation) == animation)
        }
    }
}

/// The zoom transition needs every screen that pushes a series to say which
/// cover it came from. It was wired on Discover alone; every other route
/// slid. The rule here is n of n: a file that pushes a series sets the route
/// and marks a source, or names itself below with the reason it does not.
@Suite("Every push into a series page grows out of its cover", .enabled(if: SourceTree.isAvailable))
struct ZoomRouteCoverageTests {
    /// Pushes without a zoom source, each with its reason.
    private static let exempt: [String: String] = [
        "MangaBaka/Features/Library/ShelfDetailView.swift": "unreachable; delete-or-rewire is Abdi's call"
    ]
    /// Files whose source mark lives in a sibling row view.
    private static let markedElsewhere: [String: String] = [
        "MangaBaka/Features/Schedule/ScheduleView.swift": "MangaBaka/Features/Schedule/ScheduleRow.swift"
    ]

    @Test("A file that pushes a series sets the zoom route and marks a source")
    func pushersSetTheRoute() throws {
        let files = try SourceTree.swiftFiles(under: "MangaBaka/Features")
        var pushers = 0
        for file in files where !Self.exempt.keys.contains(file) {
            let source = try SourceTree.read(file)
            guard source.contains("path.append(") else { continue }
            pushers += 1
            #expect(
                source.contains("zoomRoute?.source = ZoomRoute.id("),
                "\(file) pushes a series with no zoom route"
            )
            let marked = try SourceTree.read(Self.markedElsewhere[file] ?? file)
            #expect(marked.contains(".zoomSource("), "\(file) sets a route but marks no source view")
        }
        #expect(pushers >= 8, "Fewer pushing files than expected: the sweep found \(pushers)")
    }
}
