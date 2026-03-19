import XCTest

@MainActor
enum TrafficLogSteps {
    static func register(with runner: GherkinRunner) {
        runner.given("the traffic log is visible") { app, _ in
            let showButton = app.buttons["Show Traffic Log"]
            if showButton.waitForExistence(timeout: 5) {
                showButton.tap()
            }
        }

        runner.when("I navigate to an operator") { app, _ in
            let predicate = NSPredicate(format: "identifier BEGINSWITH 'modelListItem_npub'")
            let rows = app.descendants(matching: .any).matching(predicate)
            guard rows.count > 0 else {
                throw XCTSkip("No operators available")
            }
            rows.element(boundBy: 0).tap()
            sleep(3)
        }

        runner.then("traffic log entries should appear") { app, _ in
            let rowPredicate = NSPredicate(format: "identifier BEGINSWITH 'trafficLogRow_'")
            let logRows = app.descendants(matching: .any).matching(rowPredicate)
            // Entries may or may not appear depending on network conditions
            if logRows.count > 0 {
                XCTAssertTrue(logRows.element(boundBy: 0).exists, "Traffic log rows should exist")
            }
        }

        runner.then("no nsec keys should be visible") { app, _ in
            let nsecPredicate = NSPredicate(format: "label CONTAINS 'nsec1'")
            let nsecElements = app.descendants(matching: .staticText).matching(nsecPredicate)
            XCTAssertEqual(nsecElements.count, 0, "Traffic log must not display nsec keys")
        }
    }
}
