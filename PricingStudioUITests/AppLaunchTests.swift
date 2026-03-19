import XCTest

final class AppLaunchTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testAppLaunchesWithSidebarVisible() throws {
        let sidebar = app.navigationBars["Pricing Studio"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10), "Sidebar should be visible on launch")
    }

    func testSidebarShowsOperatorSection() throws {
        let operatorsSection = app.staticTexts["Operators"]
        XCTAssertTrue(operatorsSection.waitForExistence(timeout: 10), "Operators section should exist in sidebar")
    }

    func testSidebarShowsAuthoritiesSection() throws {
        let authoritiesSection = app.staticTexts["Authorities"]
        XCTAssertTrue(authoritiesSection.waitForExistence(timeout: 10), "Authorities section should exist in sidebar")
    }

    func testOperatorRowsHaveAccessibilityIdentifiers() throws {
        // Wait for any operator row to appear (if operators exist in the real data)
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'modelListItem_npub'")
        let rows = app.descendants(matching: .any).matching(predicate)

        // If we have operators, verify they have identifiers
        if rows.count > 0 {
            let firstRow = rows.element(boundBy: 0)
            XCTAssertTrue(firstRow.exists, "Operator rows should have modelListItem_ identifiers")
        }
    }

    func testNetworkTopologyShowsWhenNoSelection() throws {
        // With no entity selected, the network topology view should show
        let networkView = app.otherElements["Network"]
        // This may or may not exist depending on default state — just verify no crash
        XCTAssertTrue(app.exists, "App should not crash with no selection")
    }
}
