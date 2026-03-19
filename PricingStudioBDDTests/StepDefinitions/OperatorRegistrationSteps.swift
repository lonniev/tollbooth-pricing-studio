import XCTest

@MainActor
enum OperatorRegistrationSteps {
    static func register(with runner: GherkinRunner) {
        runner.given("at least one operator exists") { app, _ in
            let predicate = NSPredicate(format: "identifier BEGINSWITH 'modelListItem_npub'")
            let rows = app.descendants(matching: .any).matching(predicate)
            if rows.count == 0 {
                throw XCTSkip("No operators available — add at least one operator for BDD tests")
            }
        }

        runner.when("I tap the first operator row") { app, _ in
            let predicate = NSPredicate(format: "identifier BEGINSWITH 'modelListItem_npub'")
            let rows = app.descendants(matching: .any).matching(predicate)
            rows.element(boundBy: 0).tap()
            sleep(2)
        }

        runner.then("the pricing detail should load") { app, _ in
            // Verify pricing-related content appears
            let loadedContent = app.staticTexts["Constraints"]
                .waitForExistence(timeout: 15)
            XCTAssertTrue(loadedContent, "Pricing detail should show Constraints section")
        }

        runner.then("the operator row should have an accessibility identifier") { app, _ in
            let predicate = NSPredicate(format: "identifier BEGINSWITH 'modelListItem_npub'")
            let rows = app.descendants(matching: .any).matching(predicate)
            XCTAssertGreaterThan(rows.count, 0, "Operator rows should have modelListItem_ identifiers")
        }
    }
}
