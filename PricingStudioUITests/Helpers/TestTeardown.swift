import Foundation

/// Restores baseline pricing model via direct HTTP after mutating tests.
/// Uses real backend credentials from the test environment.
enum TestTeardown {
    /// The operator npub used for test mutations.
    /// Override via `TEST_OPERATOR_NPUB` environment variable.
    static var operatorNpub: String {
        ProcessInfo.processInfo.environment["TEST_OPERATOR_NPUB"]
            ?? "npub1test000000000000000000000000000000000000000000000000000000"
    }

    /// The MCP endpoint base URL for the test operator.
    /// Override via `TEST_MCP_ENDPOINT` environment variable.
    static var mcpEndpoint: String {
        ProcessInfo.processInfo.environment["TEST_MCP_ENDPOINT"]
            ?? "https://personal-brain.fastmcp.app"
    }

    /// Calls `set_pricing_model` via direct HTTP POST to restore baseline state.
    /// This bypasses the app's MCP client to avoid coupling test teardown to app internals.
    static func resetBaseline() async {
        guard let url = URL(string: "\(mcpEndpoint)/mcp") else { return }

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": "set_pricing_model",
                "arguments": [
                    "model_json": baselineModelJSON
                ]
            ]
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 30

        _ = try? await URLSession.shared.data(for: request)
    }

    /// Minimal baseline pricing model JSON for test reset.
    private static let baselineModelJSON = """
    {
        "name": "test-baseline",
        "is_active": true,
        "tools": [],
        "pipeline": []
    }
    """
}
