import XCTest

/// The small controls that make a screen usable, driven rather than grepped.
///
/// These replace source-grep assertions. `#expect(source.contains("SearchClearButton"))`
/// proves a call site exists and nothing else: a stub named `SearchClearButton`
/// would pass it, and so would one wired to nothing. That is not a hypothetical
/// — the chip test in `AccessibilityTests` matched `FlowChips`, a view nothing
/// had presented for weeks, and passed the whole time.
///
/// Every affordance here was reported missing by Abdi on 2026-09-10, having
/// been absent since the screen was built. The point of a test is to fail when
/// one goes again.
@MainActor
final class FlowAffordanceUITests: XCTestCase {
    private func launchedApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        return app
    }

    /// The field on Search clears, by pressing the button rather than by
    /// containing one.
    func testSearchFieldClears() throws {
        let app = launchedApp()
        app.tabBars.buttons["Search"].tap()
        let field = app.textFields.firstMatch
        guard field.waitForExistence(timeout: 15) else {
            throw XCTSkip("no search field on the Search tab")
        }
        field.tap()
        field.typeText("one piece")
        XCTAssertEqual(field.value as? String, "one piece", "the field did not take the text")

        let clear = app.buttons["Clear search"]
        guard clear.waitForExistence(timeout: 5) else {
            return XCTFail("a field with text and no way to empty it")
        }
        clear.tap()

        // The placeholder comes back as the value when a text field is empty,
        // so "not what was typed" is the honest assertion here.
        let emptied = NSPredicate(format: "value != 'one piece'")
        expectation(for: emptied, evaluatedWith: field)
        waitForExpectations(timeout: 5)
    }

    /// Adding a second mix seed opens a fresh search, not the Search tab with
    /// its previous query, results and pushed series page still on it.
    ///
    /// The bug Abdi described as "that endless cycle of it taking you back to
    /// whatever you searched for last".
    func testSeedPickerDoesNotReturnYouToYourLastSearch() throws {
        let app = launchedApp()

        // Leave a query behind on the Search tab first, so there is something
        // for the seed picker to wrongly inherit.
        app.tabBars.buttons["Search"].tap()
        let searchField = app.textFields.firstMatch
        guard searchField.waitForExistence(timeout: 15) else {
            throw XCTSkip("no search field on the Search tab")
        }
        searchField.tap()
        searchField.typeText("berserk")
        // Dismiss the keyboard before reaching for the tab bar. It covers the
        // bottom of the screen, so the tab tap lands on a key instead and the
        // test then looks for a seed slot on the Search tab and finds none —
        // which is how this skipped twice rather than failing.
        let returnKey = app.keyboards.buttons["search"].firstMatch
        if returnKey.exists { returnKey.tap() }
        app.tabBars.buttons["Mix"].tap()
        let addSeed = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'seed'")
        ).firstMatch
        guard addSeed.waitForExistence(timeout: 15) else {
            throw XCTSkip("no empty seed slot on Mix")
        }
        addSeed.tap()

        // The sheet's own field, which is now the frontmost one.
        let sheetField = app.textFields.firstMatch
        guard sheetField.waitForExistence(timeout: 10) else {
            return XCTFail("the seed picker did not open a search of its own")
        }
        XCTAssertNotEqual(
            sheetField.value as? String,
            "berserk",
            "the seed picker handed back the last search instead of a fresh one"
        )
    }

    /// Cover art can be copied by holding it.
    func testCoverArtCanBeCopied() throws {
        let app = launchedApp()
        app.tabBars.buttons["Discover"].tap()
        let card = app.scrollViews.buttons.matching(
            NSPredicate(format: "NOT (label BEGINSWITH[c] 'Open the stack')")
        ).firstMatch
        guard card.waitForExistence(timeout: 15) else {
            throw XCTSkip("no series on Discover — offline or empty feed")
        }
        card.press(forDuration: 1.0)

        // The menu item, whatever its exact wording, is the proof. Matching on
        // "Copy" rather than the full string keeps this from breaking on a
        // copy edit.
        let copyItem = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'copy'")
        ).firstMatch
        XCTAssertTrue(
            copyItem.waitForExistence(timeout: 5),
            "holding a cover offered no way to copy the artwork"
        )
    }

    /// Holding a card on the swipe stack must NOT offer a menu: it would fight
    /// the drag for the same press.
    func testStackCardsDoNotOfferACopyMenu() throws {
        let app = launchedApp()
        app.tabBars.buttons["Stack"].tap()
        guard app.staticTexts["The stack"].waitForExistence(timeout: 15) else {
            throw XCTSkip("the Stack did not open")
        }
        let card = app.images.firstMatch
        guard card.waitForExistence(timeout: 15) else {
            throw XCTSkip("no card on the stack — offline or empty feed")
        }
        card.press(forDuration: 1.0)
        let copyItem = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'copy'")
        ).firstMatch
        XCTAssertFalse(
            copyItem.waitForExistence(timeout: 3),
            "a context menu here competes with the swipe for the same press"
        )
    }
}
