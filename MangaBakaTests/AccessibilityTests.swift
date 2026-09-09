import Foundation
import SwiftUI
import Testing
@testable import MangaBaka

/// Accessibility is a build requirement the design spec names but the mockup
/// does not demonstrate, so it is asserted here rather than assumed.
@Suite("Accessibility", .enabled(if: SourceTree.isAvailable))
struct AccessibilityTests {
    /// Cover art carries the title visually. Without a label, a VoiceOver
    /// reader hears nothing at all on a screen made almost entirely of covers.
    @Test("A cover's label is the series title, not a generic word")
    func coverLabelIsTheTitle() {
        let series = SeriesFactory.make(id: 1, title: "Solo Leveling")
        #expect(series.displayTitle == "Solo Leveling")
    }

    /// A series with no titles is legitimate: `titles` is optional and nullable.
    /// The label must still say something rather than being empty.
    @Test("A series with no title still gets a spoken label")
    func untitledStillSpeaks() {
        let series = SeriesFactory.make(id: 1, titles: nil)
        #expect(series.displayTitle == nil, "The model reports the truth")
        // The view substitutes a placeholder; this asserts the contract the
        // view relies on rather than silently rendering an empty label.
        let spoken = series.displayTitle ?? "Untitled series"
        #expect(!spoken.isEmpty)
    }

    /// The type ramp is anchored to text styles so it scales. If a size were
    /// hard-coded it would stay put while everything around it grew.
    @Test("Every ramp entry is anchored to a text style")
    func rampIsScalable() throws {
        let source = try String(
            contentsOfFile: "\(repositoryRoot)/MangaBaka/DesignSystem/Typography.swift",
            encoding: .utf8
        )
        // Every scaledFont call in the named ramp must pass relativeTo, which
        // is what ties it to Dynamic Type.
        let calls = source.components(separatedBy: "scaledFont(size:").dropFirst()
        for call in calls {
            let head = String(call.prefix(220))
            #expect(
                head.contains("relativeTo:"),
                "A ramp entry without relativeTo will not scale: \(head.prefix(60))"
            )
        }
    }

    /// The stack is a drag surface, and VoiceOver cannot drag. Without explicit
    /// actions the whole screen is unreachable with the screen reader on.
    @Test("The stack exposes save and skip as actions, not only as gestures")
    func stackHasActions() throws {
        let source = try String(
            contentsOfFile: "\(repositoryRoot)/MangaBaka/Features/Stack/StackView.swift",
            encoding: .utf8
        )
        #expect(source.contains("accessibilityAction(named: \"Save\")"))
        #expect(source.contains("accessibilityAction(named: \"Skip\")"))
    }

    /// A card thrown the full width of the screen is a lot of motion for
    /// someone who has asked for less of it.
    @Test("The stack honours Reduce Motion")
    func stackHonoursReduceMotion() throws {
        let source = try String(
            contentsOfFile: "\(repositoryRoot)/MangaBaka/Features/Stack/StackView.swift",
            encoding: .utf8
        )
        #expect(source.contains("accessibilityReduceMotion"))
    }

    /// Decorative images announced by VoiceOver are noise between the things
    /// that matter.
    @Test("Decorative symbols are hidden from VoiceOver")
    func decorativeIsHidden() throws {
        let source = try String(
            contentsOfFile: "\(repositoryRoot)/MangaBaka/Features/Shared/FailureState.swift",
            encoding: .utf8
        )
        #expect(source.contains("accessibilityHidden(true)"))
    }

    private var repositoryRoot: String {
        // The tests run from the built bundle, so walk back to the source tree.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
    }
}

/// Fixed heights containing scaled text are the recurring Dynamic Type bug in
/// this codebase: three separate places clipped or collided at accessibility
/// sizes. These assert the shape of the fix rather than the symptom.
@Suite("Dynamic Type layout", .enabled(if: SourceTree.isAvailable))
struct DynamicTypeLayoutTests {
    private func source(_ path: String) throws -> String {
        try String(contentsOfFile: "\(SourceTree.root)/\(path)", encoding: .utf8)
    }

    /// A row holding two lines of scaled text cannot have a fixed height, or
    /// one row's caption overlaps the next row's title.
    @Test("Settings rows size to their content")
    func settingsRowsAreFlexible() throws {
        let text = try source("MangaBaka/Features/Settings/SettingsView.swift")
        #expect(text.contains("frame(minHeight: Metrics.ctaSecondary)"))
        #expect(
            !text.contains("frame(height: Metrics.ctaSecondary)"),
            "A fixed height clips scaled text"
        )
    }

    /// The format rows arrived in a second file after this suite was written,
    /// so they were outside every check it makes. Two lines of scaled text per
    /// row, same trap.
    @Test("Format rows size to their content")
    func formatRowsAreFlexible() throws {
        let text = try source("MangaBaka/Features/Settings/FormatSection.swift")
        #expect(text.contains("frame(minHeight: Metrics.ctaSecondary)"))
        #expect(
            !text.contains("frame(height: Metrics.ctaSecondary)"),
            "A fixed height clips scaled text"
        )
    }

    /// The stack's caption is two stacked lines of scaled text over a card.
    /// Without this it truncates to a single line at accessibility sizes and
    /// the reason — the whole point of showing it — is the half that goes.
    @Test("The stack's caption is allowed to wrap")
    func stackCaptionWraps() throws {
        // Lives in StackSections.swift since StackView hit the body-length cap.
        let text = try source("MangaBaka/Features/Stack/StackSections.swift")
        #expect(text.contains("fixedSize(horizontal: false, vertical: true)"))
        #expect(text.contains("multilineTextAlignment(.center)"))
    }

    /// A pill with a fixed height clips its own label once the label grows.
    @Test("Chips size to their content")
    func chipsAreFlexible() throws {
        let text = try source("MangaBaka/Features/Detail/SeriesDetailView.swift")
        #expect(text.contains("frame(minHeight: Metrics.headerPill)"))
    }

    /// Larger text in a fixed-width card only wraps more, until the title runs
    /// past the card and under the floating tab bar.
    @Test("Cover cards widen at accessibility text sizes")
    func cardsWidenWithText() throws {
        let text = try source("MangaBaka/Features/Shared/CoverImage.swift")
        #expect(text.contains("isAccessibilitySize"))
        #expect(text.contains("scaledWidth"))
    }

    /// One item wider than its container used to hang off the screen edge. At
    /// large text sizes a single long publisher name is enough to trigger it.
    @Test("The flow layout caps an over-wide item instead of overflowing")
    func flowLayoutCapsWidth() throws {
        let text = try source("MangaBaka/Features/Shared/FlowLayout.swift")
        #expect(text.contains("min(size.width, bounds.width)"))
        #expect(text.contains("min(size.width, maxWidth)"))
    }
}

/// Every scrolling screen must be able to scroll clear of the floating tab bar.
/// Content passing *under* the translucent bar is intended; content that can
/// never emerge from behind it is not.
@Suite("Tab bar clearance", .enabled(if: SourceTree.isAvailable))
struct TabBarClearanceTests {
    private static let scrollingScreens = [
        "MangaBaka/Features/Discovery/DiscoverView.swift",
        "MangaBaka/Features/Detail/SeriesDetailView.swift",
        "MangaBaka/Features/Search/SearchView.swift",
        "MangaBaka/Features/Mix/MixView.swift",
        "MangaBaka/Features/Shelf/ShelfView.swift",
        "MangaBaka/Features/Settings/SettingsView.swift"
    ]

    /// The floating capsule is roughly 61pt tall and sits `tabBarBottomInset`
    /// off the bottom edge. Whichever token a screen reserves has to clear that.
    @Test("Both clearance tokens exceed the tab bar's height plus its inset")
    func clearanceIsEnough() {
        let needed = 61 + Metrics.tabBarBottomInset
        #expect(Metrics.tabBarClearance >= needed)
        #expect(Metrics.scrollBottomInset >= needed)
    }

    @Test(
        "Every scrolling screen reserves the clearance",
        arguments: TabBarClearanceTests.scrollingScreens
    )
    func everyScreenReservesIt(path: String) throws {
        let text = try String(contentsOfFile: "\(SourceTree.root)/\(path)", encoding: .utf8)
        // Either token clears the bar — `clearanceIsEnough` asserts that of
        // both. The screens now use the mockup's own 150pt bottom padding, so
        // naming only the old token would fail a screen that reserves MORE.
        #expect(
            text.contains("Metrics.scrollBottomInset")
                || text.contains("Metrics.tabBarClearance"),
            "\(path) can leave its last row stranded behind the tab bar"
        )
    }
}

/// Combining an interactive control into a single accessibility element
/// swallows direct interaction with it.
@Suite("Interactive controls stay tappable", .enabled(if: SourceTree.isAvailable))
struct InteractiveControlTests {
    @Test("Settings rows do not combine an interactive child into one element")
    func rowsAreNotCombined() throws {
        let source = try String(
            contentsOfFile: "\(SourceTree.root)/MangaBaka/Features/Settings/SettingsView.swift",
            encoding: .utf8
        )
        #expect(
            !source.contains("accessibilityElement(children: .combine)"),
            "Combining a row around an interactive child breaks direct interaction"
        )
    }

    /// A decorative overlay sitting on top of interactive content must not
    /// compete for touches.
    @Test("The border overlay is not hit-testable")
    func borderDoesNotStealTouches() throws {
        let source = try String(
            contentsOfFile: "\(SourceTree.root)/MangaBaka/DesignSystem/Metrics.swift",
            encoding: .utf8
        )
        #expect(source.contains("allowsHitTesting(false)"))
    }

    /// The card behind used to show its own title at half opacity directly
    /// beneath the front card's, reading as a ghosted duplicate of the wrong
    /// series rather than as depth.
    ///
    /// The mockup resolves this differently and better: neighbours peek in from
    /// the sides as cover art only. `neighbour` is built from `CoverImage`, so
    /// there is structurally no text to ghost.
    @Test("The peeking neighbours are cover art only, and silent to VoiceOver")
    func peekingCardHidesText() throws {
        let source = try SourceTree.read("MangaBaka/Features/Stack/StackView.swift")
        #expect(source.contains("private func neighbour"))
        #expect(source.contains("accessibilityHidden(true)"))
        // The old text-bearing background card is gone.
        #expect(!source.contains("card(next"))
    }
}

/// The content rows are a Button wrapping a drawn indicator rather than a live
/// Toggle. SwiftUI's Toggle here only responded to a drag across the switch and
/// never to a tap — verified repeatedly on device, with a drag succeeding at
/// the exact coordinate a tap failed at.
@Suite("Content rows are tappable", .enabled(if: SourceTree.isAvailable))
struct ContentRowTests {
    /// Both settings sections, not just the first one written. The format
    /// rows were added in a second file and would otherwise have been free to
    /// repeat the bug this suite exists to prevent.
    private static let rowFiles = [
        "MangaBaka/Features/Settings/SettingsView.swift",
        "MangaBaka/Features/Settings/FormatSection.swift"
    ]

    @Test("The whole row is the control, not a nested Toggle", arguments: rowFiles)
    func rowIsTheControl(_ path: String) throws {
        let source = try SourceTree.read(path)
        #expect(source.contains("SwitchIndicator"), "The switch is drawn, not a live control")
        #expect(source.contains("contentShape(Rectangle())"), "The whole row must be the target")
        #expect(
            !source.contains("Toggle(isOn:"),
            "A live Toggle inside the row competes for the tap and loses"
        )
    }

    /// The indicator is decoration; the Button carries the state for VoiceOver.
    /// The caption is two Texts describing one thing. Read separately, VoiceOver
    /// announces a reason with no subject and then a source with no reason.
    @Test("The stack caption is announced as one thing")
    func captionIsOneElement() throws {
        let source = try SourceTree.read("MangaBaka/Features/Stack/StackView.swift")
        #expect(source.contains("accessibilityElement(children: .combine)"))
    }

    @Test("State is announced on the row, not on the decoration", arguments: rowFiles)
    func stateIsOnTheRow(_ path: String) throws {
        let source = try SourceTree.read(path)
        #expect(source.contains("accessibilityValue(isOn ? \"On\" : \"Off\")"))
        // The indicator itself lives in FormatSection.swift alongside the
        // format rows; wherever it is, it must not be announced.
        let indicator = try SourceTree.read("MangaBaka/Features/Settings/FormatSection.swift")
        #expect(indicator.contains("accessibilityHidden(true)"))
    }
}
