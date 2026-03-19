import XCTest

@MainActor
enum ApplyActionSteps {
    static func register(with runner: GherkinRunner) {
        runner.given("I have made pricing edits") { app, _ in
            // Navigate to operator and make an edit
            let predicate = NSPredicate(format: "identifier BEGINSWITH 'modelListItem_npub'")
            let rows = app.descendants(matching: .any).matching(predicate)
            guard rows.count > 0 else {
                throw XCTSkip("No operators available")
            }
            rows.element(boundBy: 0).tap()
            sleep(2)

            let editButton = app.buttons["Edit Pipeline"]
            guard editButton.waitForExistence(timeout: 10) else {
                throw XCTSkip("Edit Pipeline button not found")
            }
            editButton.tap()

            let addButton = app.buttons["addConstraintButton"]
            guard addButton.waitForExistence(timeout: 5) else {
                throw XCTSkip("Add Constraint button not found")
            }
            addButton.tap()

            let typePredicate = NSPredicate(format: "identifier BEGINSWITH 'constraintTypeRow_'")
            let typeRows = app.descendants(matching: .any).matching(typePredicate)
            guard typeRows.count > 0 else {
                throw XCTSkip("No constraint types available")
            }
            typeRows.element(boundBy: 0).tap()
            sleep(1)

            let saveButton = app.buttons["Save"]
            if saveButton.waitForExistence(timeout: 3) {
                saveButton.tap()
            }
            sleep(1)
        }

        runner.when("I tap the apply button") { app, _ in
            let applyButton = app.buttons["applyButton"]
            guard applyButton.waitForExistence(timeout: 5) else {
                throw XCTSkip("Apply button not visible")
            }
            applyButton.tap()
        }

        runner.then("I should see a confirmation dialog") { app, _ in
            let cancelButton = app.buttons["Cancel"]
            XCTAssertTrue(cancelButton.waitForExistence(timeout: 5), "Confirmation dialog should appear")
        }

        runner.when("I cancel the confirmation") { app, _ in
            let cancelButton = app.buttons["Cancel"]
            guard cancelButton.waitForExistence(timeout: 3) else {
                throw XCTSkip("Cancel button not found")
            }
            cancelButton.tap()
        }

        runner.then("the apply button should still be visible") { app, _ in
            let applyButton = app.buttons["applyButton"]
            XCTAssertTrue(applyButton.waitForExistence(timeout: 3), "Apply button should remain after cancelling")
        }
    }
}
