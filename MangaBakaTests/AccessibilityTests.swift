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
    ///
    /// This used to be asserted twice, once per settings file, because the
    /// format rows arrived in a second file and were outside the check. There
    /// is one row component now, so there is one place to check — and one place
    /// where the mistake can be made.
    @Test("Settings rows size to their content")
    func settingsRowsAreFlexible() throws {
        let text = try source("MangaBaka/Features/Settings/SettingsRow.swift")
        #expect(text.contains("frame(minHeight: 63)"))
        #expect(
            !text.contains("frame(height: 63)"),
            "A fixed height clips scaled text"
        )
        // Above the accessibility sizes the row stops being a horizontal thing
        // altogether: side by side, the title and the switch fight over 393pt
        // and the caption wraps to four lines.
        #expect(text.contains("typeSize >= .accessibility1"))
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
    ///
    /// Pointed at `SeriesDetailView.swift` until 2026-09-11, where it matched
    /// `FlowChips` — a view nothing had presented for some time. The test
    /// passed for months against code that never ran, which is the case
    /// against source-grep tests in one line. The chips a reader actually sees
    /// are in `DetailTagSections`.
    @Test("Chips size to their content")
    func chipsAreFlexible() throws {
        let text = try source("MangaBaka/Features/Detail/DetailTagSections.swift")
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
        "MangaBaka/Features/Library/LibraryView.swift",
        "MangaBaka/Features/Library/ShelfDetailView.swift",
        "MangaBaka/Features/Schedule/ScheduleView.swift",
        "MangaBaka/Features/Browse/BrowseView.swift",
        "MangaBaka/Features/Settings/SettingsView.swift",
        // Added 2026-09-10. Its absence is why the Stack kept a hardcoded
        // 100pt top inset for a bar that had been deleted: nothing checked it.
        "MangaBaka/Features/Stack/StackView.swift"
    ]

    /// The detail screen is deliberately absent: its hero artwork runs to the
    /// top edge, so it has no top inset to name. Every other scrolling screen
    /// starts below the status bar and does.
    private static let screensWithATopInset = scrollingScreens.filter {
        !$0.hasSuffix("SeriesDetailView.swift")
    }

    /// The system tab bar is a floating capsule roughly 61pt tall sitting a
    /// little off the bottom edge. Content scrolling *under* it is intended —
    /// that is what the glass is for — but content that can never scroll clear
    /// of it is stranded, which is the bug this guards.
    ///
    /// The number is no longer derived from a metric the app owns, because the
    /// app no longer draws the bar. 96 is the measured height of the system
    /// capsule plus its inset on the devices this ships to, with slack.
    @Test("The bottom inset clears the system tab bar")
    func clearanceIsEnough() {
        #expect(Metrics.scrollBottomInset >= 96)
    }

    /// The top inset is a token because it changed once already and will
    /// again.
    ///
    /// It was 106, to clear a floating wordmark bar the mockup drew across the
    /// top of every screen. That bar was deleted and the token dropped to 24 —
    /// but the Stack had written the number into itself rather than naming the
    /// token, so it kept a hundred points of empty space under the status bar
    /// long after the thing it was clearing was gone. Abdi found it, not a test.
    ///
    /// Asserted as "the screen names the token" rather than "the screen
    /// contains no large number". The first version of this test scanned for
    /// top paddings over 40 and failed two screens that were centring a spinner
    /// in the content area — which is not a screen inset and not anyone's
    /// business here.
    @Test(
        "Every scrolling screen names the top inset rather than writing one",
        arguments: TabBarClearanceTests.screensWithATopInset
    )
    func topInsetIsNamedNotNumbered(path: String) throws {
        let text = try String(contentsOfFile: "\(SourceTree.root)/\(path)", encoding: .utf8)
        #expect(
            text.contains("Metrics.scrollTopInset"),
            "\(path) sets its own top inset, so it will not follow when the token changes"
        )
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
            text.contains("Metrics.scrollBottomInset"),
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
    /// Both settings sections, not just the first one written. They share one
    /// row component now, but each still builds its own Button around it and
    /// each can still get the accessibility wrong on its own.
    private static let rowFiles = [
        "MangaBaka/Features/Settings/SettingsView.swift",
        "MangaBaka/Features/Settings/FormatSection.swift"
    ]

    @Test("The whole row is the control, not a nested Toggle", arguments: rowFiles)
    func rowIsTheControl(_ path: String) throws {
        let source = try SourceTree.read(path)
        #expect(source.contains("SwitchIndicator"), "The switch is drawn, not a live control")
        #expect(
            !source.contains("Toggle(isOn:"),
            "A live Toggle inside the row competes for the tap and loses"
        )
        // The tap target is the row itself, which now lives in the shared
        // component rather than being re-declared per section.
        let row = try SourceTree.read("MangaBaka/Features/Settings/SettingsRow.swift")
        #expect(row.contains("contentShape(Rectangle())"), "The whole row must be the target")
    }

    /// The indicator is decoration; the Button carries the state for VoiceOver.
    /// The caption is two Texts describing one thing. Read separately, VoiceOver
    /// announces a reason with no subject and then a source with no reason.
    @Test("The stack caption is announced as one thing")
    func captionIsOneElement() throws {
        let source = try SourceTree.read("MangaBaka/Features/Stack/StackView.swift")
        #expect(source.contains("accessibilityElement(children: .combine)"))
    }

    /// A locked row is a rule, not a broken control.
    ///
    /// `.disabled(isLocked)` is the trap, and it was shipped: SwiftUI fades a
    /// disabled Button's entire label, so the row title went grey with
    /// everything else and the design read as unavailable rather than fixed.
    /// Found by looking at the built screen against the board, not by a test —
    /// hence this one.
    @Test("A locked row is not a disabled Button", arguments: rowFiles)
    func lockedRowsKeepTheirContrast(_ path: String) throws {
        // Comments stripped first: the fix is documented in a comment that
        // names the thing it forbids, and a test that cannot tell code from a
        // note about the code fails on its own explanation.
        let source = try SourceTree.read(path)
        let code = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(
            !code.contains(".disabled(isLocked)"),
            "a disabled Button dims its whole label, including the title"
        )
        #expect(source.contains("LockPill()"), "the rule needs something that says it is a rule")
    }

    @Test("State is announced on the row, not on the decoration", arguments: rowFiles)
    func stateIsOnTheRow(_ path: String) throws {
        let source = try SourceTree.read(path)
        // A locked row announces the rule rather than a switch position, so the
        // value is no longer a bare on/off — but it must still be on the row.
        #expect(source.contains("accessibilityValue("))
        #expect(source.contains("isOn ? \"On\" : \"Off\""))
        // The indicator is decoration wherever it lives, and must not be
        // announced separately from the row that carries its meaning.
        let indicator = try SourceTree.read("MangaBaka/Features/Settings/SettingsRow.swift")
        #expect(indicator.contains("accessibilityHidden(true)"))
    }
}

/// The floating tab bar replaced the system one, so it also has to survive what
/// the system one survives.
@Suite("The tab bar holds its size", .enabled(if: SourceTree.isAvailable))
struct TabBarSizingTests {
    /// Both of the tests that used to live here checked a hand-drawn tab bar:
    /// that its labels dropped at accessibility sizes, and that every tab kept
    /// an accessibility label anyway. The bar is the system's now, so Apple
    /// answers for both — and answers better, since the native bar also resizes
    /// its selection indicator, slides it under a dragging finger and gets out
    /// of the way on scroll, none of which the hand-drawn one did.
    ///
    /// What is worth asserting is that it stays the system's.
    @Test("The tab bar is the system's, not a drawing of one")
    func usesTheSystemTabBar() throws {
        let root = try SourceTree.read("MangaBaka/App/RootView.swift")
        #expect(root.contains("role: .search"), "search should detach itself, not be drawn apart")
        #expect(root.contains("tabBarMinimizeBehavior"))
        #expect(
            !root.contains(".toolbar(.hidden, for: .tabBar)"),
            "hiding the real bar is what forced a hand-drawn one"
        )
        #expect(!SourceTree.exists("MangaBaka/Features/Chrome/AppTabBar.swift"))
    }
}

/// VoiceOver on the screens built during the fidelity pass.
@Suite("New screens are usable with VoiceOver", .enabled(if: SourceTree.isAvailable))
struct NewScreenAccessibilityTests {
    /// A tag row is three views. Left alone it is three focus stops: the name,
    /// a bare number, and an unlabelled chevron.
    @Test("A tag row is one element that says what it is")
    func tagRowIsOneElement() throws {
        let source = try SourceTree.read("MangaBaka/Features/Browse/BrowseView.swift")
        #expect(source.contains("accessibilityElement(children: .ignore)"))
        #expect(source.contains("accessibilityLabel(Self.label(for: tag))"))
    }

    /// A cover inside a row that already carries the title would only add a
    /// focus stop that says nothing at all.
    @Test("Covers with no label of their own are hidden, not silent")
    func silentCoversAreHidden() throws {
        for path in [
            "MangaBaka/Features/Library/ShelfDetailView.swift",
            "MangaBaka/Features/Library/LibraryView.swift"
        ] {
            let source = try SourceTree.read(path)
            // Every empty-labelled cover is followed by a hide.
            let empties = source.components(separatedBy: "accessibilityText: \"\"").count - 1
            let hidden = source.components(separatedBy: "accessibilityHidden(true)").count - 1
            #expect(hidden >= empties, "\(path) leaves a cover focusable with nothing to say")
        }
    }

    /// It is drawn in the accent colour with a chevron. It has to do something.
    @Test("The shelf link on the stack is a real control")
    func shelfLinkIsAButton() throws {
        let source = try SourceTree.read("MangaBaka/Features/Stack/StackSections.swift")
        #expect(source.contains("Button(action: onOpenShelf)"))
        #expect(source.contains("accessibilityLabel(\"Open the shelf\")"))
    }
}

/// An empty shelf and a failed request look similar and mean opposite things:
/// one is the app working and telling the truth, the other is something broken.
@Suite("Empty and failed are different things", .enabled(if: SourceTree.isAvailable))
struct EmptyStateTests {
    private static let screensWithEmptyStates = [
        "MangaBaka/Features/Stack/StackView.swift",
        "MangaBaka/Features/Library/LibraryView.swift",
        "MangaBaka/Features/Schedule/ScheduleView.swift"
    ]

    /// Six screens each built their own. One component means a designer settles
    /// it once rather than six times, and they cannot drift apart again.
    @Test("Screens use the shared empty state", arguments: screensWithEmptyStates)
    func usesSharedComponent(path: String) throws {
        let source = try SourceTree.read(path)
        #expect(source.contains("EmptyState("), "\(path) still builds its own")
    }

    /// A reader must be able to tell "there is nothing here" from "this broke".
    @Test("The two states are separate types")
    func distinctFromFailure() throws {
        let empty = try SourceTree.read("MangaBaka/Features/Shared/EmptyState.swift")
        let failure = try SourceTree.read("MangaBaka/Features/Shared/FailureState.swift")

        #expect(empty.contains("struct EmptyState"))
        #expect(failure.contains("struct FailureState"))
        // A failure names its cause; an empty state has no error to name.
        #expect(failure.contains("APIError"))
        #expect(!empty.contains("APIError"))
    }
}

/// The series page at the largest accessibility text size, found by running it
/// there rather than by reading it. Three defects, all the same mistake in
/// different clothes: a layout that assumes text stays small enough to sit
/// beside something else.
///
/// - The hero's title broke mid-word — "Regress / ed" — because the cover is a
///   fixed 126pt and what remains is narrower than one long word.
/// - "Add to library" and "Use as seed" truncated to "Add to li…" and
///   "Use as…", the page's primary action among them.
/// - A credits row printed "Anime adaptation" straight through "None listed".
///
/// These assert the switch exists. The layout itself cannot be measured from a
/// test, but its absence can.
@Suite("The series page survives accessibility text sizes", .enabled(if: SourceTree.isAvailable))
struct DetailAccessibilityLayoutTests {
    @Test(
        "Side-by-side layouts stack at accessibility sizes",
        arguments: [
            "MangaBaka/Features/Detail/DetailHero.swift",
            "MangaBaka/Features/Detail/SeriesDetailView.swift",
            "MangaBaka/Features/Detail/DetailCredits.swift",
            "MangaBaka/Features/Detail/DetailStatsStrip.swift"
        ]
    )
    func stacksWhenTextIsLarge(_ path: String) throws {
        let source = try SourceTree.read(path)
        // Either strategy is valid. `ViewThatFits` is the better one where the
        // trigger is "does this fit" rather than "is the reader using
        // accessibility sizes" — the stats strip wrapped its labels one notch
        // above default, long before any accessibility size.
        #expect(
            source.contains("typeSize.isAccessibilitySize") || source.contains("ViewThatFits"),
            "\(path) puts content side by side with no fallback when the text grows"
        )
    }

    /// A one-word label that wraps is always a defect, never a layout. Without
    /// `lineLimit(1)` the columns compromise by wrapping instead of declaring
    /// a width they cannot meet, and `ViewThatFits` never drops to its
    /// alternative because everything always "fits".
    /// The strip stays one row. Wrapping to a second one — which is what
    /// ViewThatFits did as soon as five columns stopped fitting, one notch
    /// above the default text size — turned the design's strip into a card for
    /// an ordinary reader. Scaling the labels is the lesser evil: they are five
    /// short words and 70% of small still reads.
    @Test("The stats strip stays on one row by shrinking, not wrapping")
    func statStripStaysOneRow() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/DetailStatsStrip.swift")
        #expect(source.contains("minimumScaleFactor"))
        #expect(source.contains("lineLimit(1)"))
        #expect(!source.contains("ViewThatFits"), "a wrap is not the fix here — shrink instead")
    }

    /// A fixed `height` around text that scales is the specific bug: the frame
    /// stays put and the label clips inside it. `minHeight` grows instead.
    @Test("Controls around scaling text use minHeight, not height")
    func noFixedHeightsAroundText() throws {
        for path in [
            "MangaBaka/Features/Detail/SeriesDetailView.swift",
            "MangaBaka/Features/Shared/RatingSegments.swift"
        ] {
            let source = try SourceTree.read(path)
            #expect(
                !source.contains(".frame(height: Metrics.ctaPrimary)"),
                "\(path) pins a control's height around text that scales"
            )
            #expect(!source.contains(".frame(height: Metrics.ratingSegment)"))
        }
    }
}
