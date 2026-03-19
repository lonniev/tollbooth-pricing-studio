import XCTest

/// Bootstrap class: launches the app, registers all step definitions,
/// and runs one test method per feature file.
@MainActor
final class PricingStudioBDDTests: XCTestCase {
    private var app: XCUIApplication!
    private var runner: GherkinRunner!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()

        runner = GherkinRunner(app: app)

        // Register all step definitions
        AppLaunchSteps.register(with: runner)
        OperatorRegistrationSteps.register(with: runner)
        PipelineEditorSteps.register(with: runner)
        ApplyActionSteps.register(with: runner)
        TrafficLogSteps.register(with: runner)
        EntityCRUDSteps.register(with: runner)
        NostrMessagingSteps.register(with: runner)
    }

    override func tearDownWithError() throws {
        app = nil
        runner = nil
    }

    // MARK: - Original Features

    func testOperatorRegistrationFeature() throws {
        runner.runFeature(named: "operator_registration", in: Bundle(for: type(of: self)))
    }

    func testPipelineEditingFeature() throws {
        runner.runFeature(named: "pipeline_editing", in: Bundle(for: type(of: self)))
    }

    func testApplyActionFeature() throws {
        runner.runFeature(named: "apply_action", in: Bundle(for: type(of: self)))
    }

    func testTrafficLogFeature() throws {
        runner.runFeature(named: "traffic_log", in: Bundle(for: type(of: self)))
    }

    // MARK: - Entity CRUD Features

    func testAuthorityCRUD() throws {
        runner.runFeature(named: "entity_crud_authority", in: Bundle(for: type(of: self)))
    }

    func testOperatorCRUD() throws {
        runner.runFeature(named: "entity_crud_operator", in: Bundle(for: type(of: self)))
    }

    func testPatronCRUD() throws {
        runner.runFeature(named: "entity_crud_patron", in: Bundle(for: type(of: self)))
    }

    // MARK: - Nostr Messaging

    func testNostrMessagingFeature() throws {
        runner.runFeature(named: "nostr_messaging", in: Bundle(for: type(of: self)))
    }
}
