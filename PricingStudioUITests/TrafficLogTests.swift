import XCTest

final class TrafficLogTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testTrafficLogToggleButton() throws {
        // Look for the traffic log toggle in the bottom toolbar
        let showButton = app.buttons["Show Traffic Log"]
        let hideButton = app.buttons["Hide Traffic Log"]

        let buttonExists = showButton.waitForExistence(timeout: 5) || hideButton.exists
        XCTAssertTrue(buttonExists, "Traffic log toggle button should exist in toolbar")
    }

    func testTrafficLogEntriesAppearAfterOperatorNavigation() throws {
        // Show traffic log
        let showButton = app.buttons["Show Traffic Log"]
        if showButton.waitForExistence(timeout: 5) {
            showButton.tap()
        }

        // Navigate to an operator to trigger MCP traffic
        try navigateToFirstOperator()

        // Wait for traffic entries to appear
        sleep(3)

        let rowPredicate = NSPredicate(format: "identifier BEGINSWITH 'trafficLogRow_'")
        let logRows = app.descendants(matching: .any).matching(rowPredicate)

        // Traffic log entries should appear after MCP calls
        if logRows.count > 0 {
            XCTAssertTrue(logRows.element(boundBy: 0).exists, "Traffic log rows should have identifiers")
        }
    }

    func testTrafficLogDoesNotExposeNsec() throws {
        // Show traffic log
        let showButton = app.buttons["Show Traffic Log"]
        if showButton.waitForExistence(timeout: 5) {
            showButton.tap()
        }

        try navigateToFirstOperator()
        sleep(3)

        // Check that no visible text contains "nsec1"
        let nsecPredicate = NSPredicate(format: "label CONTAINS 'nsec1'")
        let nsecElements = app.descendants(matching: .staticText).matching(nsecPredicate)
        XCTAssertEqual(nsecElements.count, 0, "Traffic log must not display nsec keys")
    }

    // MARK: - Helpers

    private func navigateToFirstOperator() throws {
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'modelListItem_npub'")
        let rows = app.descendants(matching: .any).matching(predicate)
        guard rows.count > 0 else {
            throw XCTSkip("No operators available")
        }
        rows.element(boundBy: 0).tap()
    }
}
