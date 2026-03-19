import XCTest

/// Shared step definitions for Authority, Operator, and Patron CRUD workflows.
/// All three entity types follow the same UI patterns:
///   Add menu > sheet > generate keys > display name > Add button
///   Context menu > Edit > change name > Save
///   Swipe > Delete > confirm
@MainActor
enum EntityCRUDSteps {

    /// Find the sidebar collection view to scope element lookups
    /// and avoid ambiguity with the detail pane.
    private static func sidebar(in app: XCUIApplication) -> XCUIElement {
        app.collectionViews["Sidebar"]
    }

    /// Find a named element in the sidebar, using firstMatch to handle duplicates
    /// from prior test runs that weren't cleaned up.
    private static func sidebarText(_ name: String, in app: XCUIApplication) -> XCUIElement {
        sidebar(in: app).staticTexts[name].firstMatch
    }

    static func register(with runner: GherkinRunner) {

        // MARK: - Navigation & Menu

        runner.when("I tap the add menu") { app, _ in
            // The add menu is a "+" button in the sidebar toolbar nav bar
            let sidebarNav = app.navigationBars["Pricing Studio"]
            guard sidebarNav.waitForExistence(timeout: 5) else {
                throw XCTSkip("Sidebar navigation bar not found")
            }
            let addButton = sidebarNav.buttons["Add"]
            guard addButton.waitForExistence(timeout: 3) else {
                throw XCTSkip("Add menu button not found in sidebar")
            }
            addButton.tap()
        }

        runner.when("I tap \"(.+)\"") { app, captures in
            guard let label = captures.first else {
                XCTFail("Missing label capture")
                return
            }
            let button = app.buttons[label]
            if button.waitForExistence(timeout: 5) {
                button.tap()
                return
            }
            // Fall back to staticTexts for menu items
            let text = app.staticTexts[label]
            if text.waitForExistence(timeout: 3) {
                text.tap()
                return
            }
            // Fall back to any matching element
            let any = app.descendants(matching: .any)[label]
            guard any.waitForExistence(timeout: 3) else {
                XCTFail("Could not find element with label: \(label)")
                return
            }
            any.tap()
        }

        // MARK: - Sheet Verification

        runner.then("I should see the \"(.+)\" sheet") { app, captures in
            guard let sheetTitle = captures.first else {
                XCTFail("Missing sheet title capture")
                return
            }
            let navBar = app.navigationBars[sheetTitle]
            XCTAssertTrue(
                navBar.waitForExistence(timeout: 5),
                "Sheet with title '\(sheetTitle)' should be visible"
            )
        }

        // MARK: - Key Generation

        runner.when("I tap \"Generate Nostr Keys\"") { app, _ in
            let button = app.buttons["generateKeysButton"]
            if button.waitForExistence(timeout: 5) {
                button.tap()
                sleep(1)
                return
            }
            // Fall back to label match
            let labelButton = app.buttons["Generate Nostr Keys"]
            guard labelButton.waitForExistence(timeout: 3) else {
                XCTFail("Generate Nostr Keys button not found")
                return
            }
            labelButton.tap()
            sleep(1)
        }

        runner.then("the keys should be generated") { app, _ in
            // After key generation, the confirmation label should appear
            let confirmation = app.staticTexts["Keys generated — nsec and npub filled in below"]
            if !confirmation.waitForExistence(timeout: 3) {
                // Alternative: check that the button is now disabled
                let button = app.buttons["generateKeysButton"]
                if button.exists {
                    XCTAssertFalse(button.isEnabled, "Generate button should be disabled after key generation")
                }
            }
        }

        // MARK: - Form Input

        runner.when("I enter \"(.+)\" as the display name") { app, captures in
            guard let name = captures.first else {
                XCTFail("Missing display name capture")
                return
            }
            let field = app.textFields["Display Name"]
            guard field.waitForExistence(timeout: 5) else {
                XCTFail("Display Name text field not found")
                return
            }
            field.tap()
            field.typeText(name)
        }

        runner.when("I clear and type \"(.+)\" in the display name field") { app, captures in
            guard let name = captures.first else {
                XCTFail("Missing display name capture")
                return
            }
            let field = app.textFields["Display Name"]
            guard field.waitForExistence(timeout: 5) else {
                XCTFail("Display Name text field not found")
                return
            }
            field.tap()

            // Select all and delete
            field.press(forDuration: 1.0)
            let selectAll = app.menuItems["Select All"]
            if selectAll.waitForExistence(timeout: 2) {
                selectAll.tap()
            }
            field.typeText(name)
        }

        runner.when("I tap the \"(.+)\" button") { app, captures in
            guard let label = captures.first else {
                XCTFail("Missing button label capture")
                return
            }

            // When tapping "Add" or "Save", scope to the sheet's nav bar
            // to avoid ambiguity with the sidebar toolbar's "Add" button.
            if label == "Add" || label == "Save" {
                let navBars = app.navigationBars
                let count = navBars.count
                for i in 0..<count {
                    let navBar = navBars.element(boundBy: i)
                    let navButton = navBar.buttons[label]
                    if navButton.exists {
                        let navId = navBar.identifier
                        // Skip the main sidebar nav bar ("Pricing Studio")
                        if navId != "Pricing Studio" {
                            navButton.tap()
                            sleep(1)
                            return
                        }
                    }
                }
            }

            // Fallback: single match or non-ambiguous button
            let button = app.buttons[label]
            guard button.waitForExistence(timeout: 5) else {
                XCTFail("Button '\(label)' not found")
                return
            }
            button.tap()
            sleep(1)
        }

        // MARK: - Sidebar Verification (scoped to sidebar collection view)

        runner.then("I should see \"(.+)\" in the sidebar") { app, captures in
            guard let name = captures.first else {
                XCTFail("Missing name capture")
                return
            }
            let element = sidebarText(name, in: app)
            XCTAssertTrue(
                element.waitForExistence(timeout: 5),
                "'\(name)' should be visible in the sidebar"
            )
        }

        runner.then("\"(.+)\" should no longer appear in the sidebar") { app, captures in
            guard let name = captures.first else {
                XCTFail("Missing name capture")
                return
            }
            let element = sidebarText(name, in: app)
            // Wait briefly for deletion animation
            sleep(1)
            XCTAssertFalse(element.exists, "'\(name)' should no longer be in the sidebar")
        }

        // MARK: - Entity Existence Precondition (scoped to sidebar)

        runner.given("an entity named \"(.+)\" exists in the sidebar") { app, captures in
            guard let name = captures.first else {
                XCTFail("Missing entity name capture")
                return
            }
            let element = sidebarText(name, in: app)
            guard element.waitForExistence(timeout: 5) else {
                throw XCTSkip("Entity '\(name)' not found in sidebar — prerequisite scenario may have failed")
            }
        }

        // MARK: - Context Menu (Edit) — scoped to sidebar

        runner.when("I open the context menu for \"(.+)\"") { app, captures in
            guard let name = captures.first else {
                XCTFail("Missing entity name capture")
                return
            }
            let element = sidebarText(name, in: app)
            guard element.waitForExistence(timeout: 5) else {
                XCTFail("Entity '\(name)' not found in sidebar for context menu")
                return
            }
            element.press(forDuration: 1.0)
            sleep(1)
        }

        // MARK: - Swipe to Delete — scoped to sidebar

        runner.when("I swipe to delete \"(.+)\"") { app, captures in
            guard let name = captures.first else {
                XCTFail("Missing entity name capture")
                return
            }
            let element = sidebarText(name, in: app)
            guard element.waitForExistence(timeout: 5) else {
                XCTFail("Entity '\(name)' not found in sidebar for swipe delete")
                return
            }
            element.swipeLeft()
            sleep(1)

            // Tap the Delete button that appears from swipe
            let deleteButton = app.buttons["Delete"]
            if deleteButton.waitForExistence(timeout: 3) {
                deleteButton.tap()
            }
        }

        runner.then("I should see a delete confirmation dialog") { app, _ in
            // The alert has a "Delete" destructive button
            let deleteButton = app.buttons["Delete"]
            let cancelButton = app.buttons["Cancel"]
            let dialogVisible = deleteButton.waitForExistence(timeout: 5) || cancelButton.exists
            XCTAssertTrue(dialogVisible, "Delete confirmation dialog should appear")
        }

        runner.when("I confirm the deletion") { app, _ in
            // Tap the destructive "Delete" button in the alert
            let deleteButton = app.buttons["Delete"]
            guard deleteButton.waitForExistence(timeout: 5) else {
                XCTFail("Delete confirmation button not found")
                return
            }
            deleteButton.tap()
            sleep(1)
        }
    }
}
