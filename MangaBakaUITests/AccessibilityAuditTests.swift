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

    private func audit(_ app: XCUIApplication, screen: String) throws {
        var lines: [String] = []
        try app.performAccessibilityAudit(for: Self.audits) { issue in
            let element = issue.element?.description ?? "unknown element"
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

    /// The series page, which carries more distinct controls than any other
    /// screen in the app.
    func testSeriesDetailPassesTheAudit() throws {
        let app = launchedApp()
        app.tabBars.buttons["Discover"].tap()
        let cover = app.scrollViews.buttons.firstMatch
        guard cover.waitForExistence(timeout: 15) else {
            throw XCTSkip("no series on Discover to open — offline or empty feed")
        }
        cover.tap()
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 10)
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
}
