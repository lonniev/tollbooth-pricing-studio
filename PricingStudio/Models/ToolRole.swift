import Foundation

/// Indicates which identity a tool call should authenticate with.
enum ToolRole {
    /// Patron identity — balance checks, purchases, session ops.
    case patron
    /// Operator identity — pricing changes, credential certification.
    case `operator`
    /// Ambiguous — could be either perspective; prompt the user.
    case ambiguous
}

/// Classifies MCP tool names into the identity role needed to call them.
enum ToolRoleClassifier {

    private static let operatorTools: Set<String> = [
        "set_pricing_model",
        "certify_credits",
        "register_operator",
        "operator_status",
    ]

    private static let patronTools: Set<String> = [
        "check_balance",
        "purchase_credits",
        "check_payment",
        "session_status",
        "service_status",
        "restore_credits",
        "forget_credentials",
        "receive_credentials",
        "request_credential_channel",
    ]

    private static let ambiguousTools: Set<String> = [
        "account_statement",
        "account_statement_infographic",
        "get_pricing_model",
    ]

    /// Classify a tool name by the identity role it requires.
    ///
    /// Tool names may include a prefix (e.g. `brain_set_pricing_model`);
    /// classification checks the suffix.
    static func classify(_ toolName: String) -> ToolRole {
        // Strip common prefixes — operators prefix tools with their slug
        let stripped = stripPrefix(toolName)

        if operatorTools.contains(stripped) { return .operator }
        if patronTools.contains(stripped) { return .patron }
        if ambiguousTools.contains(stripped) { return .ambiguous }

        // Default unknown tools to patron (safe fallback)
        return .patron
    }

    /// Remove operator-slug prefixes like `brain_`, `excalibur_`, `authority_`.
    private static func stripPrefix(_ name: String) -> String {
        if let range = name.range(of: "_", options: .backwards) {
            // If the suffix matches a known tool, use it
            let suffix = String(name[name.index(after: range.lowerBound)...])
            // Check 2-part suffixes first (e.g. "set_pricing_model")
            for known in operatorTools.union(patronTools).union(ambiguousTools) {
                if name.hasSuffix(known) {
                    return known
                }
            }
            // Single-word suffix
            if operatorTools.contains(suffix) || patronTools.contains(suffix) || ambiguousTools.contains(suffix) {
                return suffix
            }
        }
        return name
    }
}
