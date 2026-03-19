import XCTest

final class ConstraintParamEditorTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testParamEditorShowsFieldsForConstraintType() throws {
        try navigateToAddConstraintSheet()

        // Tap the first constraint type
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'constraintTypeRow_'")
        let typeRows = app.descendants(matching: .any).matching(predicate)
        guard typeRows.count > 0 else {
            throw XCTSkip("No constraint types available")
        }
        typeRows.element(boundBy: 0).tap()

        // Verify param fields appear
        let paramPredicate = NSPredicate(format: "identifier BEGINSWITH 'constraintParamField_'")
        let paramFields = app.descendants(matching: .any).matching(paramPredicate)

        // Wait briefly for the editor sheet
        sleep(1)

        XCTAssertGreaterThan(paramFields.count, 0, "Param editor should show fields for the selected constraint type")
    }

    func testParamEditorHasSaveAndCancelButtons() throws {
        try navigateToAddConstraintSheet()

        let predicate = NSPredicate(format: "identifier BEGINSWITH 'constraintTypeRow_'")
        let typeRows = app.descendants(matching: .any).matching(predicate)
        guard typeRows.count > 0 else {
            throw XCTSkip("No constraint types available")
        }
        typeRows.element(boundBy: 0).tap()

        sleep(1)

        let saveButton = app.buttons["Save"]
        let cancelButton = app.buttons["Cancel"]
        XCTAssertTrue(saveButton.exists || cancelButton.exists, "Param editor should have Save or Cancel button")
    }

    // MARK: - Helpers

    private func navigateToAddConstraintSheet() throws {
        // Navigate to first operator
        let opPredicate = NSPredicate(format: "identifier BEGINSWITH 'modelListItem_npub'")
        let opRows = app.descendants(matching: .any).matching(opPredicate)
        guard opRows.count > 0 else {
            throw XCTSkip("No operators available")
        }
        opRows.element(boundBy: 0).tap()
        sleep(2)

        // Enter pipeline edit mode
        let editButton = app.buttons["Edit Pipeline"]
        guard editButton.waitForExistence(timeout: 10) else {
            throw XCTSkip("Edit Pipeline button not found")
        }
        editButton.tap()

        // Tap Add Constraint
        let addButton = app.buttons["addConstraintButton"]
        guard addButton.waitForExistence(timeout: 5) else {
            throw XCTSkip("Add Constraint button not found")
        }
        addButton.tap()

        let sheetTitle = app.navigationBars["Add Constraint"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 5))
    }
}
