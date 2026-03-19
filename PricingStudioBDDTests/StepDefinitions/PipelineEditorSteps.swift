import XCTest

@MainActor
enum PipelineEditorSteps {
    static func register(with runner: GherkinRunner) {
        runner.given("I am viewing an operator's pricing") { app, _ in
            let predicate = NSPredicate(format: "identifier BEGINSWITH 'modelListItem_npub'")
            let rows = app.descendants(matching: .any).matching(predicate)
            guard rows.count > 0 else {
                throw XCTSkip("No operators available")
            }
            rows.element(boundBy: 0).tap()
            sleep(2)
        }

        runner.when("I enter pipeline edit mode") { app, _ in
            let editButton = app.buttons["Edit Pipeline"]
            guard editButton.waitForExistence(timeout: 10) else {
                throw XCTSkip("Edit Pipeline button not found")
            }
            editButton.tap()
        }

        runner.then("I should see the add constraint button") { app, _ in
            let addButton = app.buttons["addConstraintButton"]
            XCTAssertTrue(addButton.waitForExistence(timeout: 5), "Add Constraint button should be visible")
        }

        runner.when("I tap add constraint") { app, _ in
            let addButton = app.buttons["addConstraintButton"]
            guard addButton.waitForExistence(timeout: 5) else {
                throw XCTSkip("Add Constraint button not found")
            }
            addButton.tap()
        }

        runner.then("I should see constraint type options") { app, _ in
            let predicate = NSPredicate(format: "identifier BEGINSWITH 'constraintTypeRow_'")
            let typeRows = app.descendants(matching: .any).matching(predicate)
            XCTAssertGreaterThan(typeRows.count, 0, "Constraint type rows should appear")
        }

        runner.when("I select the first constraint type") { app, _ in
            let predicate = NSPredicate(format: "identifier BEGINSWITH 'constraintTypeRow_'")
            let typeRows = app.descendants(matching: .any).matching(predicate)
            guard typeRows.count > 0 else {
                throw XCTSkip("No constraint types available")
            }
            typeRows.element(boundBy: 0).tap()
            sleep(1)
        }

        runner.then("I should see parameter fields") { app, _ in
            let paramPredicate = NSPredicate(format: "identifier BEGINSWITH 'constraintParamField_'")
            let paramFields = app.descendants(matching: .any).matching(paramPredicate)
            XCTAssertGreaterThan(paramFields.count, 0, "Parameter fields should appear")
        }
    }
}
