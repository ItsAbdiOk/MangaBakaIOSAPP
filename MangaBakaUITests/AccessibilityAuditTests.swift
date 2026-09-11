import XCTest

/// Apple's own accessibility audit, run over every screen.
///
/// This is mechanical where the design review was manual: `performAccessibilityAudit`
/// walks the real view hierarchy and reports contrast failures, missing
/// descriptions, hit regions under 44x44pt, clipped text at large Dynamic Type
/// sizes and elements VoiceOver cannot see. A human reviewer finds the worst
/// three; this finds all of them, on every screen, every time it runs.
///
/// Deliberately NOT in the scheme's test action, for the same reason as the
/// performance tests: it launches a real app per test and is slow. Run it on
/// purpose:
///   xcodebuild test -scheme MangaBaka -only-testing:MangaBakaUITests
// Swift 6 makes XCUIApplication main-actor-isolated, so every test that
// touches it has to be too.
@MainActor
final class AccessibilityAuditTests: XCTestCase {

    /// Everything Apple audits. Listed explicitly rather than passing `.all`,
    /// so that adding a category in a future SDK is a deliberate act and shows
    /// up as a new failure rather than silently changing what "all" meant.
    private static let audits: XCUIAccessibilityAuditType = [
        .contrast,
        .dynamicType,
        .elementDetection,
        .hitRegion,
        .sufficientElementDescription,
        .textClipped,
        .trait
    ]

    /// Where the details go.
    ///
    /// The audit's own failure messages are five words long ("Contrast
    /// failed"), which tells you there is a problem and nothing about where.
    /// The issue handler carries the element and a full description, so every
    /// issue is written out with the screen it was found on.
    private static let logURL = URL(fileURLWithPath: "/tmp/mb-a11y-audit.txt")

    /// The screen as the audit saw it, saved beside the report.
    ///
    /// Without this the frames in the report cannot be checked: the audit
    /// launches its own app, so a screenshot taken afterwards by hand shows a
    /// different feed at a different scroll position, and sampling it answers
    /// a question nobody asked. Learned by doing exactly that.
    private func capture(_ screen: String) {
        let image = XCUIScreen.main.screenshot().image
        guard let data = image.pngData() else { return }
        let safe = screen.replacingOccurrences(of: " ", with: "-").lowercased()
        try? data.write(to: URL(fileURLWithPath: "/tmp/mb-a11y-\(safe).png"))
    }

    /// Fails rather than audits when navigation did not arrive.
    ///
    /// The first version of the deeper tests tapped its way in and audited
    /// whatever was on screen. Two of them never left Discover and filed its
    /// issues under "Cover gallery" and "Stack mid-drag" — a false record,
    /// which is worse than no record. Every screen now proves it is itself
    /// before anything is measured.
    private func arrived(_ element: XCUIElement, _ screen: String) -> Bool {
        guard element.waitForExistence(timeout: 10) else {
            XCTFail("never reached \(screen): its marker element never appeared")
            return false
        }
        return true
    }

    private func audit(_ app: XCUIApplication, screen: String) throws {
        capture(screen)
        var lines: [String] = []
        try app.performAccessibilityAudit(for: Self.audits) { issue in
            // Flattened: an element's description can carry a newline — a
            // synopsis, a long note — and one of those splits a row of this
            // tab-separated log into two, which then reads as a screen named
            // after half a sentence.
            let element = (issue.element?.description ?? "unknown element")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
            // The frame, because "Contrast failed" on a title drawn in a colour
            // that measures 18:1 against the app's ground is not a claim about
            // the colour — it is a claim about what is really behind it at that
            // point on screen. Without coordinates the report can only be
            // guessed at, and it was.
            let frame = issue.element.map { element -> String in
                let rect = element.frame
                return String(
                    format: "%.0f,%.0f %.0fx%.0f",
                    rect.origin.x, rect.origin.y, rect.size.width, rect.size.height
                )
            } ?? "-"
            lines.append(
                "\(screen)\t\(issue.auditType)\t\(issue.compactDescription)\t\(element)\t\(frame)"
            )
            // false = do not ignore; the issue still fails the test.
            return false
        }
        if !lines.isEmpty { Self.append(lines) }
    }

    private static func append(_ lines: [String]) {
        let text = lines.joined(separator: "\n") + "\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    /// Launched per test rather than in `setUp`, which is not main-actor
    /// isolated and so cannot touch `XCUIApplication` under Swift 6.
    private func launchedApp() -> XCUIApplication {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launch()
        return app
    }

    /// Every tab, audited where it opens.
    func testTabsPassTheAudit() throws {
        let app = launchedApp()
        for tab in ["Discover", "Stack", "Mix", "Library"] {
            let button = app.tabBars.buttons[tab]
            guard button.waitForExistence(timeout: 10) else {
                XCTFail("no \(tab) tab to audit")
                continue
            }
            button.tap()
            // The screen has to have drawn before it can be audited; an audit
            // of a half-built view reports the placeholder, not the screen.
            _ = app.staticTexts.firstMatch.waitForExistence(timeout: 5)
            try audit(app, screen: tab)
        }
    }

    /// The label every hero cover carries, and nothing else does.
    private static let heroCover = NSPredicate(format: "label BEGINSWITH[c] 'Cover art for'")

    /// Opens a series from Discover and proves the page arrived.
    ///
    /// Taking `app.scrollViews.buttons.firstMatch` does NOT open a series: the
    /// first button on Discover is the "Open the stack" card, so the series
    /// detail audit spent its life auditing the Stack and filing the result
    /// under "Series detail". Found on 2026-09-11 by looking at the screenshot
    /// the audit had saved of itself.
    private func openSeries(in app: XCUIApplication) throws -> XCUIElement {
        app.tabBars.buttons["Discover"].tap()
        let card = app.scrollViews.buttons.matching(
            NSPredicate(format: "NOT (label BEGINSWITH[c] 'Open the stack')")
        ).firstMatch
        guard card.waitForExistence(timeout: 15) else {
            throw XCTSkip("no series on Discover to open — offline or empty feed")
        }
        card.tap()
        let hero = app.buttons.matching(Self.heroCover).firstMatch
        guard arrived(hero, "Series detail") else {
            throw XCTSkip("the series page never opened")
        }
        return hero
    }

    /// The series page, which carries more distinct controls than any other
    /// screen in the app.
    func testSeriesDetailPassesTheAudit() throws {
        let app = launchedApp()
        _ = try openSeries(in: app)
        try audit(app, screen: "Series detail")
    }

    /// Settings, where the app has the most text per point of screen.
    func testSettingsPassesTheAudit() throws {
        let app = launchedApp()
        app.tabBars.buttons["Library"].tap()
        let gear = app.buttons["Settings"]
        guard gear.waitForExistence(timeout: 10) else {
            throw XCTSkip("no Settings control found from Library")
        }
        gear.tap()
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 5)
        try audit(app, screen: "Settings")
    }

    /// The blocked-tags screen, reached from Settings.
    ///
    /// One of the six the device review never got to. Added here rather than
    /// looked at once: a screen audited by hand is audited on the day somebody
    /// remembers to, and this one is two taps deep where nobody goes.
    func testBlockedTagsPassesTheAudit() throws {
        let app = launchedApp()
        app.tabBars.buttons["Library"].tap()
        let gear = app.buttons["Settings"]
        guard gear.waitForExistence(timeout: 10) else {
            throw XCTSkip("no Settings control found from Library")
        }
        gear.tap()
        let blocked = app.staticTexts["Block a tag"]
        guard blocked.waitForExistence(timeout: 10) else {
            throw XCTSkip("no blocked-tags control in Settings")
        }
        blocked.tap()
        guard arrived(app.navigationBars["Block a tag"], "Blocked tags") else { return }
        try audit(app, screen: "Blocked tags")
    }

    /// The cover gallery, which is the only full-screen surface in the app.
    func testCoverGalleryPassesTheAudit() throws {
        let app = launchedApp()
        let hero = try openSeries(in: app)
        hero.tap()
        // The gallery is a full-screen cover with its own Done button; that
        // button existing is the only proof it opened.
        guard arrived(app.buttons["Done"], "Cover gallery") else { return }
        try audit(app, screen: "Cover gallery")
    }

    /// The Library with its inline search showing results, rather than idle.
    ///
    /// The review audited the Library at rest. A list with results in it is a
    /// different screen: different row contents, a clear button, a count.
    func testLibrarySearchResultsPassTheAudit() throws {
        let app = launchedApp()
        app.tabBars.buttons["Library"].tap()
        let field = app.searchFields.firstMatch.exists
            ? app.searchFields.firstMatch
            : app.textFields.firstMatch
        guard field.waitForExistence(timeout: 15) else {
            throw XCTSkip("no search field on Library")
        }
        field.tap()
        field.typeText("a")
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 5)
        try audit(app, screen: "Library search results")
    }

    /// A shelf, opened from the Library — if anything still opens one.
    ///
    /// `ShelfDetailView` exists, is tested, and has a navigation destination
    /// waiting for it in `RootView`. Nothing presents it: the cards that used
    /// to, `LibraryView.shelfCards` and `searchResults`, had no callers and
    /// were removed on 2026-09-11 as dead code. The Library shows a filter row
    /// and a flat list instead, which is a reasonable replacement for shelves
    /// — but it means a whole screen is unreachable, and whether to wire it
    /// back up or delete it is Abdi's call, not one to make at 2am.
    ///
    /// Skipped with that reason rather than deleted, so the question stays
    /// visible in the test output until it is answered.
    func testShelfDetailPassesTheAudit() throws {
        throw XCTSkip("""
        ShelfDetailView is currently unreachable: nothing in LibraryView \
        presents a shelf card. See docs/unknowns-2026-09-11.md.
        """)
    }

    /// A stack card held mid-drag, with its SKIP or SAVE badge showing.
    ///
    /// The badges are at `opacity(0)` at rest, which is why a static audit of
    /// the Stack says nothing about them — and why the contrast failures it
    /// reported for them were measuring bare artwork. Held here instead.
    func testStackMidDragPassesTheAudit() throws {
        let app = launchedApp()
        app.tabBars.buttons["Stack"].tap()
        guard arrived(app.staticTexts["The stack"], "Stack") else { return }
        let card = app.images.firstMatch
        guard card.waitForExistence(timeout: 15) else {
            throw XCTSkip("no card on the stack — offline or empty feed")
        }
        // Press, move, and hold: releasing would commit the swipe and the
        // badge would be gone before the audit ran.
        let start = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = card.coordinate(withNormalizedOffset: CGVector(dx: 1.4, dy: 0.5))
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 1.5)
        try audit(app, screen: "Stack mid-drag")
    }
}
