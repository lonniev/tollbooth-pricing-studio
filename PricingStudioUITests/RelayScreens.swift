import XCTest

/// Drives the new Relays sidebar section + RelayView and captures screenshots
/// as test attachments (exportable via xcresulttool). Not an assertion-heavy
/// test — its job is visual confirmation of the Relays diagnostics feature.
final class RelayScreens: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        dismissSplashIfPresent()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testRelaysSectionAndDetail() throws {
        // 1) Sidebar with the Relays section.
        let relayRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'relayRow-'"))
        XCTAssertTrue(
            relayRow.element(boundBy: 0).waitForExistence(timeout: 20),
            "At least one relay row should appear in the sidebar Relays section"
        )
        snap("01-sidebar-relays")

        // 2) Open the first relay's RelayView.
        relayRow.element(boundBy: 0).tap()
        let healthButton = app.buttons["Run Health Check"]
        XCTAssertTrue(healthButton.waitForExistence(timeout: 10), "RelayView should show a Run Health Check button")
        snap("02-relay-view")

        // 3) Run the health check and capture the result.
        healthButton.tap()
        sleep(6)
        XCTAssertTrue(app.staticTexts["Online"].waitForExistence(timeout: 12), "Health check should report Online")
        snap("03-relay-health-check")

        // 4) Switch to a different relay — the RelayView must reset (no stale
        //    ping result carried over from the peer relay).
        let second = relayRow.element(boundBy: 1)
        guard second.exists else { throw XCTSkip("Only one relay available") }
        second.tap()
        XCTAssertTrue(app.buttons["Run Health Check"].waitForExistence(timeout: 10))
        XCTAssertFalse(
            app.staticTexts["Online"].exists,
            "Switching relays must clear the previous relay's health-check result"
        )
        snap("04-switched-relay-clean")
    }

    // MARK: - Helpers

    private func dismissSplashIfPresent() {
        let begin = app.staticTexts["Tap to begin"]
        if begin.waitForExistence(timeout: 5) {
            begin.tap()
        } else {
            // Fallback: tap the center to dismiss any resume splash.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
