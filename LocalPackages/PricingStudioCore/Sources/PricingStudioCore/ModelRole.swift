import Foundation

/// LLM conversation roles in Pricing Studio. Each role has its own OpenRouter
/// model slug (persisted in UserDefaults, not secret) so Owl, Advisors, and the
/// adversarial second opinion can pick different models independently.
public enum ModelRole: String, CaseIterable, Sendable, Codable {
    case owl
    case advisor
    case adversary

    /// Default OpenRouter slug for this role.
    public var defaultSlug: String {
        switch self {
        case .owl: return "anthropic/claude-sonnet-5"
        case .advisor: return "anthropic/claude-sonnet-5"
        case .adversary: return "x-ai/grok-4.5"
        }
    }

    /// Short human title used in Settings and headers.
    public var title: String {
        switch self {
        case .owl: return "Owl"
        case .advisor: return "Advisor"
        case .adversary: return "Second opinion"
        }
    }

    /// Visible label shown in conversation headers / reply chrome.
    /// Adversary is always tagged "(adversarial)".
    public func displayLabel(slug: String) -> String {
        switch self {
        case .owl:
            return "🦉 Owl · \(slug)"
        case .advisor:
            return "Advisor · \(slug)"
        case .adversary:
            return "Second opinion · \(slug) (adversarial)"
        }
    }

    /// Suggested slugs offered in Settings pickers (Claude + Grok).
    public var suggestedSlugs: [String] {
        [
            "anthropic/claude-sonnet-5",
            "anthropic/claude-opus-4.1",
            "anthropic/claude-haiku-4.5",
            "x-ai/grok-4.5",
            "x-ai/grok-4",
            "x-ai/grok-3",
        ]
    }
}

/// UserDefaults-backed storage for per-role model slugs. Not secret — slugs are
/// public model identifiers, only the OpenRouter API key is Keychain-stored.
public enum ModelRoleSettings {
    public static func defaultsKey(for role: ModelRole) -> String {
        "com.tollbooth.dpyc.PricingStudio.modelRole.\(role.rawValue)"
    }

    public static func slug(for role: ModelRole, defaults: UserDefaults = .standard) -> String {
        let raw = defaults.string(forKey: defaultsKey(for: role))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? role.defaultSlug : raw
    }

    public static func setSlug(_ slug: String, for role: ModelRole, defaults: UserDefaults = .standard) {
        let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: defaultsKey(for: role))
        } else {
            defaults.set(trimmed, forKey: defaultsKey(for: role))
        }
    }

    public static func displayLabel(for role: ModelRole, defaults: UserDefaults = .standard) -> String {
        role.displayLabel(slug: slug(for: role, defaults: defaults))
    }
}

/// Pure request builder for OpenRouter's Anthropic-compatible Messages endpoint.
/// Keeps URL, headers, and body construction host-free so unit tests can assert
/// the wire shape without networking.
public enum OpenRouterRequestBuilder {
    public static let messagesURL = URL(string: "https://openrouter.ai/api/v1/messages")!

    public struct BuiltRequest: Sendable {
        public let url: URL
        public let headers: [String: String]
        public let body: Data
    }

    public static func build(
        model: String,
        apiKey: String,
        systemPrompt: String,
        messages: [[String: Any]],
        maxTokens: Int,
        stream: Bool,
        tools: [[String: Any]]?
    ) -> BuiltRequest {
        var headers: [String: String] = [
            "Content-Type": "application/json",
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
        ]
        // OpenRouter optionally accepts these; harmless on the Anthropic-compat path.
        headers["HTTP-Referer"] = "https://github.com/lonniev/tollbooth-pricing-studio"
        headers["X-Title"] = "Pricing Studio"

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": stream,
            "system": systemPrompt,
            "messages": messages,
        ]
        if let tools, !tools.isEmpty {
            body["tools"] = tools
        }
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        return BuiltRequest(url: messagesURL, headers: headers, body: data)
    }

    /// Map API error responses to clear, actionable user messages in OpenRouter terms.
    public static func friendlyErrorMessage(
        statusCode: Int,
        body: String,
        role: ModelRole?
    ) -> String {
        let lower = body.lowercased()
        switch statusCode {
        case 400 where lower.contains("credit") || lower.contains("balance") || lower.contains("billing"):
            return "[OpenRouter credits exhausted. Add credits at openrouter.ai/settings/credits before continuing.]"
        case 401:
            return "[OpenRouter API key is invalid or expired. Check your OpenRouter key in Settings.]"
        case 404:
            if let role {
                return "[Unknown model for \(role.title). Fix the \(role.title) model slug in Settings → Models.]"
            }
            return "[Unknown model slug. Fix the model in Settings → Models.]"
        case 429:
            return "[OpenRouter rate limit reached. Wait a moment and try again.]"
        case 529, 503:
            return "[OpenRouter is temporarily overloaded. Try again in a few seconds.]"
        default:
            return "[OpenRouter error (HTTP \(statusCode)). Check Settings or try again later.]"
        }
    }
}
