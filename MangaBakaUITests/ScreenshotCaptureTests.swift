import XCTest

/// Captures the app's six main screens for App Store screenshots, with real
/// cover art switched off (Abdi, 2026-09-15: screenshots and promo material
/// must never show real covers — licensing). Launches with
/// `-placeholder-covers`, which `ScreenshotMode.isActive` reads to make
/// every `CoverImage` draw a generated gradient instead of network art or a
/// BlurHash — see `CoverImage.swift`.
///
/// Gated on the `MB_CAPTURE_SCREENSHOTS` environment variable rather than
/// living in its own scheme: the ordinary accessibility scheme
/// (`AccessibilityAuditTests`) and every unit-test run launch this test class
/// too, and without the gate this would capture and audit-skip its way
/// through a full app launch on every one of those runs. `xcodebuild` does
/// not forward the invoking shell's environment into the test process by
/// default — see `docs/release/screenshots.md` for how to actually set the
/// variable when running this.
///
/// This test only captures; it makes no accessibility assertions. That is
/// `AccessibilityAuditTests`'s job, run separately, against the real covers
/// this test deliberately hides.
///
/// `@MainActor` for the same reason as `AccessibilityAuditTests`: Swift 6
/// makes `XCUIApplication` main-actor-isolated.
@MainActor
final class ScreenshotCaptureTests: XCTestCase {
    /// Where captures land. `/tmp` rather than the scratchpad: this runs from
    /// whatever machine invokes `xcodebuild`, not from an agent session, and
    /// the brief for this test names this exact path.
    private static let outputDirectory = "/tmp/mb-shots"

    /// How long to wait for a screen's marker element, and separately for its
    /// content to have actually drawn, before giving up. 15s, per the brief —
    /// generous because the first Discover load after a fresh launch also
    /// pays for the feed request.
    private static let contentTimeout: TimeInterval = 15

    /// The label every hero cover carries, and nothing else does — the same
    /// marker `AccessibilityAuditTests.heroCover` uses to prove a series page
    /// arrived, duplicated here because that constant is `private` there.
    private static let heroCover = NSPredicate(format: "label BEGINSWITH[c] 'Cover art for'")

    /// `-onboarding.completed YES` skips the carousel, exactly as
    /// `AccessibilityAuditTests.launchedApp()` does. `-placeholder-covers`
    /// is the flag this whole test exists to exercise.
    private func launchedApp() -> XCUIApplication {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments += ["-onboarding.completed", "YES", "-placeholder-covers"]
        app.launch()
        return app
    }

    /// Waits for the screen to have real content on it — not a skeleton — then
    /// saves the screenshot. Polling both `staticTexts` and `images` rather
    /// than either alone: Library signed out draws its empty state entirely in
    /// text, and the covers grids draw mostly images, so a check on only one
    /// kind would pass instantly on the other screen with nothing to show yet.
    private func waitAndCapture(_ app: XCUIApplication, name: String, index: Int) {
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: Self.contentTimeout)
        _ = app.images.firstMatch.waitForExistence(timeout: Self.contentTimeout)
        let image = XCUIScreen.main.screenshot().image
        guard let data = image.pngData() else { return }
        let path = "\(Self.outputDirectory)/\(String(format: "%02d", index))-\(name).png"
        try? data.write(to: URL(fileURLWithPath: path))
        print("Saved screenshot: \(path)")
    }

    /// Opens the first real series from Discover (skipping the "Open the
    /// stack" card, the same exclusion `AccessibilityAuditTests.openSeries`
    /// uses) and captures its top.
    private func captureSeriesPage(in app: XCUIApplication) {
        app.tabBars.buttons["Discover"].tap()
        // The changelog card ("New in this build") is a button on Discover
        // too and has no series page behind it — the second capture
        // (2026-09-15, 15:36) tapped it and never found a hero.
        let cards = app.scrollViews.buttons.matching(
            NSPredicate(
                format: "NOT (label BEGINSWITH[c] 'Open the stack') AND NOT (label BEGINSWITH[c] 'New in this build')"
            )
        )
        guard cards.firstMatch.waitForExistence(timeout: Self.contentTimeout) else { return }
        cards.firstMatch.tap()
        let hero = app.buttons.matching(Self.heroCover).firstMatch
        guard hero.waitForExistence(timeout: Self.contentTimeout) else { return }
        // The fan, not just the hero: the third capture (2026-09-15, 15:39)
        // caught the page under a throttle — "Too many requests, briefly"
        // over a lone cover — because two capture runs in three minutes had
        // spent MangaBaka's window. The covers leg re-asks itself when the
        // window passes, so waiting for a fanned cover waits out the bar.
        // Up to a minute (the gate's own window); a series with a single
        // cover falls through after that and is captured as it is.
        _ = app.buttons["Another cover for this series"].firstMatch.waitForExistence(timeout: 60)
        waitAndCapture(app, name: "series", index: 2)
        // Seed Mix from here, so frame 6 is a blend rather than the honest
        // empty state the first capture (2026-09-15) caught. The button
        // moves the app to the Mix tab; the tab taps that follow bring it
        // back. UNVERIFIED on a capture run — written while the sim lane
        // was taken.
        let seed = app.buttons["Use as seed"]
        // The pager keeps the neighbouring series page built, so there are
        // two "Use as seed" buttons in the tree (fifth capture, 2026-09-15:
        // "Multiple matching elements") — which is also why the fourth
        // reported the single query not hittable. The on-screen one is the
        // hittable one.
        if seed.waitForExistence(timeout: Self.contentTimeout),
           let onScreen = app.buttons.matching(identifier: "Use as seed")
               .allElementsBoundByIndex.first(where: \.isHittable) {
            onScreen.tap()
        }
    }

    /// Types into Search's field — a search field where one exists, else the
    /// plain text field, matching `AccessibilityAuditTests`'s own fallback —
    /// and captures the results for a real, populated query.
    private func captureSearchResults(in app: XCUIApplication) {
        app.tabBars.buttons["Search"].tap()
        let field = app.searchFields.firstMatch.exists
            ? app.searchFields.firstMatch
            : app.textFields.firstMatch
        guard field.waitForExistence(timeout: Self.contentTimeout) else { return }
        field.tap()
        field.typeText("apothecary\n")
        // Return submits the search and drops the keyboard; the first run
        // captured the keyboard and then tapped tabs it was covering, so
        // screens 3–6 were all this one.
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
        // The results grid, not the idle page: the first capture fired as
        // soon as any text and image existed, which the idle page's inline
        // filter panel satisfies. A card whose label carries the query is
        // the only thing that proves results are up. UNVERIFIED on a
        // capture run.
        let result = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'apothecary'")
        ).firstMatch
        _ = result.waitForExistence(timeout: Self.contentTimeout)
        waitAndCapture(app, name: "search", index: 3)
        // Leave search so the tab bar is reachable again. With a search
        // role on the tab bar there is no Cancel: the bar collapses to one
        // pill (label "Discover", value "Collapsed") and tapping it expands
        // the tabs — the second capture failed on "Stack" not existing.
        let cancel = app.buttons["Cancel"]
        if cancel.exists, cancel.isHittable { cancel.tap() }
        expandTabBar(in: app)
    }

    private func expandTabBar(in app: XCUIApplication) {
        guard !app.tabBars.buttons["Stack"].exists else { return }
        let collapsed = app.tabBars.buttons.firstMatch
        if collapsed.waitForExistence(timeout: 3) { collapsed.tap() }
        _ = app.tabBars.buttons["Stack"].waitForExistence(timeout: 3)
    }

    /// The six screens named in the brief: Discover top, a series page top,
    /// Search results, Stack, Library (signed out — its honest empty state is
    /// fine), Mix.
    func testCaptureAppStoreScreenshots() throws {
        guard ProcessInfo.processInfo.environment["MB_CAPTURE_SCREENSHOTS"] == "1" else {
            throw XCTSkip("only runs when MB_CAPTURE_SCREENSHOTS=1 is set on the test process")
        }
        try? FileManager.default.createDirectory(
            atPath: Self.outputDirectory, withIntermediateDirectories: true
        )
        let app = launchedApp()

        app.tabBars.buttons["Discover"].tap()
        waitAndCapture(app, name: "discover", index: 1)

        captureSeriesPage(in: app)
        captureSearchResults(in: app)

        app.tabBars.buttons["Stack"].tap()
        waitAndCapture(app, name: "stack", index: 4)

        app.tabBars.buttons["Library"].tap()
        waitAndCapture(app, name: "library", index: 5)

        app.tabBars.buttons["Mix"].tap()
        // Blend the seed planted from the series page, so the frame is a
        // result grid rather than one filled slot over an enabled button
        // (sixth capture, 2026-09-15). The grid is a row of cover buttons;
        // waiting on a second one rules out the seed tile itself.
        //
        // Used to wait on `scrollViews.buttons.element(boundBy: 3)` — the
        // discovery-ui review (2026-09-15) found that index lands on a
        // filter chip, not a result card, so this could capture the frame
        // before the blend had actually finished. `MixResults` tags each
        // result card with `.accessibilityIdentifier("mix.resultCard")`
        // (added for this); waiting on the *second* one (`boundBy: 1`) keeps
        // the original intent of ruling out the seed tile.
        let blend = app.buttons["Blend"].firstMatch
        if blend.waitForExistence(timeout: 5), blend.isHittable {
            blend.tap()
            let secondResultCard = app.buttons.matching(identifier: "mix.resultCard").element(boundBy: 1)
            _ = secondResultCard.waitForExistence(timeout: 30)
        }
        waitAndCapture(app, name: "mix", index: 6)
    }
}
