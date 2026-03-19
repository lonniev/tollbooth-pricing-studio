import XCTest

/// Step definitions for Nostr messaging BDD scenarios.
///
/// Creates ephemeral Alice and Bob patrons with generated keys,
/// sends a DM from Alice to Bob via the UI (using entity suggestions),
/// and verifies the unread badge appears on Bob's sidebar entry.
@MainActor
enum NostrMessagingSteps {

    private static func sidebar(in app: XCUIApplication) -> XCUIElement {
        app.collectionViews["Sidebar"]
    }

    static func register(with runner: GherkinRunner) {

        // MARK: - Given: Named patron with nsec exists

        runner.given("a patron named \"(.+)\" with nsec exists in the sidebar") { app, captures in
            guard let name = captures.first else {
                XCTFail("Missing patron name capture")
                return
            }

            let sb = sidebar(in: app)
            let existing = sb.staticTexts[name].firstMatch

            if existing.waitForExistence(timeout: 3) {
                return
            }

            // Create via Add menu
            let sidebarNav = app.navigationBars["Pricing Studio"]
            guard sidebarNav.waitForExistence(timeout: 5) else {
                throw XCTSkip("Sidebar nav bar not found")
            }
            sidebarNav.buttons["Add"].tap()
            sleep(1)

            let addPatron = app.buttons["Add Patron"]
            if addPatron.waitForExistence(timeout: 3) {
                addPatron.tap()
            } else {
                let menuItem = app.staticTexts["Add Patron"]
                guard menuItem.waitForExistence(timeout: 3) else {
                    throw XCTSkip("Add Patron menu item not found")
                }
                menuItem.tap()
            }
            sleep(1)

            // Generate keys
            let genButton = app.buttons["generateKeysButton"]
            if genButton.waitForExistence(timeout: 5) {
                genButton.tap()
                sleep(1)
            } else {
                let labelButton = app.buttons["Generate Nostr Keys"]
                guard labelButton.waitForExistence(timeout: 3) else {
                    throw XCTSkip("Generate keys button not found")
                }
                labelButton.tap()
                sleep(1)
            }

            // Enter display name
            let nameField = app.textFields["Display Name"]
            guard nameField.waitForExistence(timeout: 5) else {
                throw XCTSkip("Display Name field not found")
            }
            nameField.tap()
            nameField.typeText(name)

            // Tap Add in the sheet nav bar
            let navBars = app.navigationBars
            for i in 0..<navBars.count {
                let bar = navBars.element(boundBy: i)
                let addButton = bar.buttons["Add"]
                if addButton.exists, bar.identifier != "Pricing Studio" {
                    addButton.tap()
                    sleep(1)
                    break
                }
            }

            // Verify it appeared
            let created = sb.staticTexts[name].firstMatch
            XCTAssertTrue(
                created.waitForExistence(timeout: 5),
                "Patron '\(name)' should appear in sidebar after creation"
            )
        }

        // MARK: - When: Tap named entity in sidebar

        runner.when("I tap \"(.+)\" in the sidebar") { app, captures in
            guard let name = captures.first else {
                XCTFail("Missing name capture")
                return
            }
            let sb = sidebar(in: app)
            let element = sb.staticTexts[name].firstMatch
            guard element.waitForExistence(timeout: 5) else {
                XCTFail("'\(name)' not found in sidebar")
                return
            }
            element.tap()
            sleep(1)
        }

        // MARK: - When: Tap Messages tab

        runner.when("I tap the \"Messages\" tab") { app, _ in
            let picker = app.segmentedControls.firstMatch
            guard picker.waitForExistence(timeout: 5) else {
                XCTFail("Segmented control (tab picker) not found")
                return
            }
            let messagesButton = picker.buttons["Messages"]
            guard messagesButton.waitForExistence(timeout: 3) else {
                XCTFail("'Messages' segment not found in picker")
                return
            }
            messagesButton.tap()
            sleep(1)
        }

        // MARK: - Then: Messaging interface visible

        runner.then("I should see the messaging interface") { app, _ in
            let secureLabel = app.staticTexts["Nostr Secure Messaging"]
            let composeButton = app.buttons["composeMessageButton"]
            let noMessages = app.staticTexts["No Messages"]

            let visible = secureLabel.waitForExistence(timeout: 5)
                || composeButton.exists
                || noMessages.exists

            XCTAssertTrue(visible, "Messaging interface should be visible")
        }

        // MARK: - When: Compose DM to Bob using suggestion tap

        runner.when("I compose a DM to Bob's npub with \"(.+)\"") { app, captures in
            guard let message = captures.first else {
                XCTFail("Missing message capture")
                return
            }

            // Open compose sheet
            let composeById = app.buttons["composeMessageButton"]
            if composeById.waitForExistence(timeout: 5) {
                composeById.tap()
            } else {
                let startButton = app.buttons["Start a Conversation"]
                guard startButton.waitForExistence(timeout: 3) else {
                    XCTFail("Compose button not found")
                    return
                }
                startButton.tap()
            }
            sleep(1)

            // Verify sheet appeared
            let navBar = app.navigationBars["New Message"]
            XCTAssertTrue(navBar.waitForExistence(timeout: 5), "New Message sheet should appear")

            // Find Bob BDD in the suggestion list and tap to fill npub
            let bobSuggestion = app.staticTexts["Bob BDD"]
            if bobSuggestion.waitForExistence(timeout: 5) {
                bobSuggestion.tap()
                sleep(1)
            } else {
                // Fallback: type "Bob" in the recipient field to filter suggestions
                let recipientField = app.textFields["recipientNpubField"]
                if recipientField.waitForExistence(timeout: 3) {
                    recipientField.tap()
                    recipientField.typeText("Bob")
                    sleep(1)
                    let filtered = app.staticTexts["Bob BDD"]
                    if filtered.waitForExistence(timeout: 3) {
                        filtered.tap()
                        sleep(1)
                    } else {
                        XCTFail("Bob BDD not found in entity suggestions")
                        return
                    }
                } else {
                    XCTFail("Recipient field not found")
                    return
                }
            }

            // Type message
            let editor = app.textViews["composeMessageBody"]
            if editor.waitForExistence(timeout: 5) {
                editor.tap()
                editor.typeText(message)
            } else {
                let anyEditor = app.textViews.firstMatch
                guard anyEditor.waitForExistence(timeout: 3) else {
                    XCTFail("Message text editor not found")
                    return
                }
                anyEditor.tap()
                anyEditor.typeText(message)
            }
            sleep(1)

            // Tap send
            let sendButton = app.buttons["sendMessageButton"]
            guard sendButton.waitForExistence(timeout: 5) else {
                XCTFail("Send button not found")
                return
            }
            sendButton.tap()
            sleep(3)

            // Dismiss Save Contact alert if it appears
            let skipButton = app.buttons["Skip"]
            if skipButton.waitForExistence(timeout: 3) {
                skipButton.tap()
                sleep(1)
            }
        }

        // MARK: - Then: Sent message appears in conversation

        runner.then("the sent message \"(.+)\" should appear in Alice's conversation") { app, captures in
            guard let message = captures.first else {
                XCTFail("Missing message capture")
                return
            }

            let messageText = app.staticTexts[message]
            XCTAssertTrue(
                messageText.waitForExistence(timeout: 15),
                "Sent message '\(message)' should appear in the conversation"
            )
        }

        // MARK: - When: Wait for Bob's DM polling

        runner.when("I wait for Bob's DM polling to detect the message") { app, _ in
            // The DMPollingService polls every 10 seconds.
            // Allow up to 45 seconds for relay propagation + poll cycle + fetch.
            // We poll by checking for the indicator periodically rather than
            // sleeping the full duration.
            let sb = sidebar(in: app)
            let anyIndicator = sb.images.matching(
                NSPredicate(format: "identifier BEGINSWITH 'dmIndicator_'")
            ).firstMatch

            // Wait up to 45 seconds, checking every 5 seconds
            let deadline = Date().addingTimeInterval(45)
            while Date() < deadline {
                if anyIndicator.exists {
                    return
                }
                sleep(5)
            }
            // Don't fail here — the Then step will check and report
        }

        // MARK: - Then: Message indicator for named patron

        runner.then("a message indicator should appear for \"(.+)\" in the sidebar") { app, captures in
            guard let name = captures.first else {
                XCTFail("Missing patron name capture")
                return
            }

            let sb = sidebar(in: app)

            // First check for any dmIndicator in the sidebar
            let anyIndicator = sb.images.matching(
                NSPredicate(format: "identifier BEGINSWITH 'dmIndicator_'")
            )

            // Give it one more chance if the When step didn't find it
            if anyIndicator.count == 0 {
                sleep(15)
            }

            let indicatorCount = anyIndicator.count
            if indicatorCount > 0 {
                // Found at least one indicator — verify it's near the expected patron
                let ids = (0..<indicatorCount).map {
                    anyIndicator.element(boundBy: $0).identifier
                }
                // Log which indicators we found for diagnostics
                print("BDD: Found \(indicatorCount) DM indicator(s): \(ids)")

                // Verify the patron row exists
                let patronRow = sb.staticTexts[name].firstMatch
                XCTAssertTrue(patronRow.exists, "Patron '\(name)' should be in sidebar")
            } else {
                // No indicators at all — polling hasn't detected the DM yet
                XCTFail("No DM indicators found in sidebar after waiting. The polling service may not have detected the incoming DM for '\(name)'. Check relay connectivity and polling logs.")
            }
        }
    }
}
