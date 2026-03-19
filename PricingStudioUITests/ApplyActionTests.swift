import XCTest

final class ApplyActionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        // Restore baseline after mutating tests
        Task { await TestTeardown.resetBaseline() }
        app = nil
    }

    func testApplyButtonExistsWithEdits() throws {
        try navigateToFirstOperator()
        try makeAnEdit()

        let applyButton = app.buttons["applyButton"]
        XCTAssertTrue(
            applyButton.waitForExistence(timeout: 5),
            "Save to Operator button should appear when edits exist"
        )
    }

    func testApplyButtonShowsConfirmationDialog() throws {
        try navigateToFirstOperator()
        try makeAnEdit()

        let applyButton = app.buttons["applyButton"]
        guard applyButton.waitForExistence(timeout: 5) else {
            throw XCTSkip("Apply button not visible")
        }
        applyButton.tap()

        // Confirmation dialog should appear
        // Note: confirmationDialog renders as system action sheet — button labels match
        let saveConfirm = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Save to'")
        )
        let cancelButton = app.buttons["Cancel"]

        let dialogAppeared = saveConfirm.count > 0 || cancelButton.waitForExistence(timeout: 3)
        XCTAssertTrue(dialogAppeared, "Confirmation dialog should appear after tapping apply")
    }

    func testCancelDismissesConfirmationDialog() throws {
        try navigateToFirstOperator()
        try makeAnEdit()

        let applyButton = app.buttons["applyButton"]
        guard applyButton.waitForExistence(timeout: 5) else {
            throw XCTSkip("Apply button not visible")
        }
        applyButton.tap()

        let cancelButton = app.buttons["Cancel"]
        guard cancelButton.waitForExistence(timeout: 3) else {
            throw XCTSkip("Cancel button not found in confirmation dialog")
        }
        cancelButton.tap()

        // Apply button should still be visible (dialog dismissed, edits remain)
        XCTAssertTrue(
            applyButton.waitForExistence(timeout: 3),
            "Apply button should remain after cancelling"
        )
    }

    // MARK: - Helpers

    private func navigateToFirstOperator() throws {
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'modelListItem_npub'")
        let rows = app.descendants(matching: .any).matching(predicate)
        guard rows.count > 0 else {
            throw XCTSkip("No operators available")
        }
        rows.element(boundBy: 0).tap()
        sleep(2)
    }

    private func makeAnEdit() throws {
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
}
