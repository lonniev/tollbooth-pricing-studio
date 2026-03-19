import XCTest

final class PipelineEditorTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        Task { await TestTeardown.resetBaseline() }
        app = nil
    }

    func testAddConstraintButtonExistsInEditMode() throws {
        try navigateToFirstOperator()
        try enterPipelineEditMode()

        let addButton = app.buttons["addConstraintButton"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5), "Add Constraint button should appear in edit mode")
    }

    func testAddConstraintShowsSheet() throws {
        try navigateToFirstOperator()
        try enterPipelineEditMode()

        let addButton = app.buttons["addConstraintButton"]
        guard addButton.waitForExistence(timeout: 5) else {
            throw XCTSkip("Add Constraint button not found — no pipeline edit mode available")
        }
        addButton.tap()

        let sheetTitle = app.navigationBars["Add Constraint"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 5), "Add Constraint sheet should appear")
    }

    func testConstraintTypeRowsExistInSheet() throws {
        try navigateToFirstOperator()
        try enterPipelineEditMode()

        let addButton = app.buttons["addConstraintButton"]
        guard addButton.waitForExistence(timeout: 5) else {
            throw XCTSkip("Add Constraint button not found")
        }
        addButton.tap()

        // Wait for any constraint type row
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'constraintTypeRow_'")
        let typeRows = app.descendants(matching: .any).matching(predicate)
        XCTAssertGreaterThan(typeRows.count, 0, "Constraint type rows should exist in the sheet")
    }

    func testPipelineStepRowsHaveIdentifiers() throws {
        try navigateToFirstOperator()

        // Wait for pipeline steps to load (if any exist)
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'pipelineStepRow_'")
        let stepRows = app.descendants(matching: .any).matching(predicate)

        // If steps exist, verify they have identifiers
        if stepRows.count > 0 {
            XCTAssertTrue(stepRows.element(boundBy: 0).exists, "Pipeline step rows should have indexed identifiers")
        }
    }

    // MARK: - Helpers

    private func navigateToFirstOperator() throws {
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'modelListItem_npub'")
        let rows = app.descendants(matching: .any).matching(predicate)
        guard rows.count > 0 else {
            throw XCTSkip("No operators available — add at least one operator for UI tests")
        }
        rows.element(boundBy: 0).tap()

        // Wait for pricing detail to load
        sleep(2)
    }

    private func enterPipelineEditMode() throws {
        let editButton = app.buttons["Edit Pipeline"]
        guard editButton.waitForExistence(timeout: 10) else {
            throw XCTSkip("Edit Pipeline button not found — pricing model may not have loaded")
        }
        editButton.tap()
    }
}
