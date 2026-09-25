import XCTest
@testable import PricingStudioCore

/// Confirms OpenRouter routing + per-role model selection (issue #161).
/// These fail before the feature exists: defaults, persistence, request shape.
final class OpenRouterModelRoleTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "OpenRouterModelRoleTests.\(UUID().uuidString)")!
    }

    override func tearDown() {
        if let suite = defaults {
            for key in suite.dictionaryRepresentation().keys {
                suite.removeObject(forKey: key)
            }
        }
        defaults = nil
        super.tearDown()
    }

    func testRoleDefaultsMatchDesign() {
        XCTAssertEqual(ModelRole.owl.defaultSlug, "anthropic/claude-sonnet-5")
        XCTAssertEqual(ModelRole.advisor.defaultSlug, "anthropic/claude-sonnet-5")
        XCTAssertEqual(ModelRole.adversary.defaultSlug, "x-ai/grok-4.5")
    }

    func testDisplayLabels() {
        XCTAssertEqual(
            ModelRole.owl.displayLabel(slug: "anthropic/claude-sonnet-5"),
            "🦉 Owl · anthropic/claude-sonnet-5"
        )
        XCTAssertEqual(
            ModelRole.advisor.displayLabel(slug: "anthropic/claude-sonnet-5"),
            "Advisor · anthropic/claude-sonnet-5"
        )
        XCTAssertEqual(
            ModelRole.adversary.displayLabel(slug: "x-ai/grok-4.5"),
            "Second opinion · x-ai/grok-4.5 (adversarial)"
        )
    }

    func testSlugPersistsAcrossReads() {
        XCTAssertEqual(ModelRoleSettings.slug(for: .adversary, defaults: defaults),
                       ModelRole.adversary.defaultSlug)

        ModelRoleSettings.setSlug("x-ai/grok-4", for: .adversary, defaults: defaults)

        XCTAssertEqual(ModelRoleSettings.slug(for: .adversary, defaults: defaults), "x-ai/grok-4")
        // Other roles stay at defaults.
        XCTAssertEqual(ModelRoleSettings.slug(for: .owl, defaults: defaults), ModelRole.owl.defaultSlug)
    }

    func testEmptySlugFallsBackToDefault() {
        ModelRoleSettings.setSlug("   ", for: .owl, defaults: defaults)
        XCTAssertEqual(ModelRoleSettings.slug(for: .owl, defaults: defaults), ModelRole.owl.defaultSlug)
    }

    func testRequestBuilderTargetsOpenRouterWithRoleModel() throws {
        let built = OpenRouterRequestBuilder.build(
            model: "x-ai/grok-4.5",
            apiKey: "or-test-key",
            systemPrompt: "sys",
            messages: [["role": "user", "content": "hi"]],
            maxTokens: 128,
            stream: true,
            tools: nil
        )

        XCTAssertEqual(built.url.absoluteString, "https://openrouter.ai/api/v1/messages")
        XCTAssertEqual(built.headers["x-api-key"], "or-test-key")
        XCTAssertEqual(built.headers["anthropic-version"], "2023-06-01")
        XCTAssertEqual(built.headers["Content-Type"], "application/json")

        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: built.body) as? [String: Any]
        )
        XCTAssertEqual(json["model"] as? String, "x-ai/grok-4.5")
        XCTAssertEqual(json["max_tokens"] as? Int, 128)
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["system"] as? String, "sys")
        XCTAssertNil(json["tools"])
    }

    func testRequestBuilderIncludesToolsWhenProvided() throws {
        let tools: [[String: Any]] = [["name": "oracle_about", "description": "x", "input_schema": ["type": "object"]]]
        let built = OpenRouterRequestBuilder.build(
            model: "anthropic/claude-sonnet-5",
            apiKey: "k",
            systemPrompt: "s",
            messages: [],
            maxTokens: 64,
            stream: true,
            tools: tools
        )
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: built.body) as? [String: Any]
        )
        let bodyTools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertEqual(bodyTools.count, 1)
        XCTAssertEqual(bodyTools[0]["name"] as? String, "oracle_about")
    }

    func testFriendlyErrorsNameOpenRouterAndRole() {
        let credits = OpenRouterRequestBuilder.friendlyErrorMessage(
            statusCode: 400,
            body: #"{"error":{"message":"credit balance too low"}}"#,
            role: .owl
        )
        XCTAssertTrue(credits.localizedCaseInsensitiveContains("OpenRouter"), credits)
        XCTAssertFalse(credits.localizedCaseInsensitiveContains("Anthropic"), credits)

        let badKey = OpenRouterRequestBuilder.friendlyErrorMessage(
            statusCode: 401,
            body: "unauthorized",
            role: nil
        )
        XCTAssertTrue(badKey.localizedCaseInsensitiveContains("OpenRouter"), badKey)

        let unknown = OpenRouterRequestBuilder.friendlyErrorMessage(
            statusCode: 404,
            body: #"{"error":{"message":"model not found"}}"#,
            role: .adversary
        )
        XCTAssertTrue(unknown.localizedCaseInsensitiveContains("adversary")
                      || unknown.localizedCaseInsensitiveContains("Second opinion")
                      || unknown.localizedCaseInsensitiveContains("Settings"), unknown)
    }
}
