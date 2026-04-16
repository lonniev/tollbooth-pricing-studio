import Foundation

// MARK: - Parameter type taxonomy

enum ParamType {
    case int
    case float
    case string
    case bool
    case schedule      // "HH:MM-HH:MM" time range
    case timezone      // IANA timezone identifier
    case tiers         // array of tier dictionaries
    case daysOfWeek    // array of day indices (0=Mon..6=Sun, ISO 8601)
}

// MARK: - Parameter specification

struct ParamSpec {
    let name: String
    let type: ParamType
    let required: Bool
    let defaultValue: AnyCodableValue?
    let description: String
}

// MARK: - Constraint specification

struct ConstraintSpec {
    let type: PipelineStepType
    let category: String          // "Pricing", "Access", "Dynamic"
    let description: String
    let params: [ParamSpec]
}

// MARK: - Catalog

struct ConstraintCatalog {

    static let all: [ConstraintSpec] = [

        // ---------------------------------------------------------------
        // MARK: Pricing constraints
        // ---------------------------------------------------------------

        ConstraintSpec(
            type: .freeTrial,
            category: "Pricing",
            description: "Grant the first N invocations for free.",
            params: [
                ParamSpec(
                    name: "first_n_free",
                    type: .int,
                    required: true,
                    defaultValue: .int(5),
                    description: "Number of free invocations granted to each patron."
                ),
            ]
        ),

        ConstraintSpec(
            type: .coupon,
            category: "Pricing",
            description: "Apply a discount when a valid coupon code is supplied.",
            params: [
                ParamSpec(
                    name: "code",
                    type: .string,
                    required: true,
                    defaultValue: nil,
                    description: "The coupon code string."
                ),
                ParamSpec(
                    name: "discount_percent",
                    type: .float,
                    required: false,
                    defaultValue: .double(0.0),
                    description: "Percentage discount (0-100)."
                ),
                ParamSpec(
                    name: "discount_sats",
                    type: .int,
                    required: false,
                    defaultValue: .int(0),
                    description: "Absolute discount in api-sats."
                ),
                ParamSpec(
                    name: "free",
                    type: .bool,
                    required: false,
                    defaultValue: .bool(false),
                    description: "If true, the tool call is free when this coupon is applied."
                ),
                ParamSpec(
                    name: "max_redemptions",
                    type: .int,
                    required: false,
                    defaultValue: nil,
                    description: "Optional global cap on total redemptions."
                ),
                ParamSpec(
                    name: "max_per_patron",
                    type: .int,
                    required: false,
                    defaultValue: nil,
                    description: "Optional per-patron redemption cap."
                ),
                ParamSpec(
                    name: "expires_at",
                    type: .string,
                    required: false,
                    defaultValue: nil,
                    description: "Optional ISO-8601 expiry datetime."
                ),
            ]
        ),

        ConstraintSpec(
            type: .loyaltyDiscount,
            category: "Pricing",
            description: "Reward patrons who have consumed at least a threshold of api-sats.",
            params: [
                ParamSpec(
                    name: "threshold_consumed_api_sats",
                    type: .int,
                    required: true,
                    defaultValue: .int(10000),
                    description: "Minimum api-sats consumed before the discount activates."
                ),
                ParamSpec(
                    name: "discount_percent",
                    type: .float,
                    required: true,
                    defaultValue: .double(10.0),
                    description: "Percentage discount applied once the threshold is met."
                ),
            ]
        ),

        ConstraintSpec(
            type: .bulkBonus,
            category: "Pricing",
            description: "Tiered bonus multiplier based on total consumption.",
            params: [
                ParamSpec(
                    name: "tiers",
                    type: .tiers,
                    required: true,
                    defaultValue: nil,
                    description: "Array of tiers, each with min_consumed (api-sats) and bonus_multiplier."
                ),
            ]
        ),

        ConstraintSpec(
            type: .happyHour,
            category: "Pricing",
            description: "Apply a pricing discount during a temporal window.",
            params: [
                ParamSpec(
                    name: "schedule",
                    type: .schedule,
                    required: true,
                    defaultValue: .string("17:00-19:00"),
                    description: "HH:MM-HH:MM time range (24-hour). Wraps midnight when end < start."
                ),
                ParamSpec(
                    name: "timezone",
                    type: .timezone,
                    required: false,
                    defaultValue: .string("UTC"),
                    description: "IANA timezone name (e.g. US/Eastern)."
                ),
                ParamSpec(
                    name: "discount_percent",
                    type: .float,
                    required: false,
                    defaultValue: .double(25.0),
                    description: "Percentage discount during the happy hour window."
                ),
                ParamSpec(
                    name: "discount_sats",
                    type: .int,
                    required: false,
                    defaultValue: .int(0),
                    description: "Absolute discount in api-sats during the happy hour window."
                ),
                ParamSpec(
                    name: "free",
                    type: .bool,
                    required: false,
                    defaultValue: .bool(false),
                    description: "If true, the tool call is free during the happy hour window."
                ),
                ParamSpec(
                    name: "days_of_week",
                    type: .daysOfWeek,
                    required: false,
                    defaultValue: .array([.int(0), .int(1), .int(2), .int(3), .int(4)]),
                    description: "Days when the happy hour is active (0=Mon, 1=Tue, 2=Wed, 3=Thu, 4=Fri, 5=Sat, 6=Sun)."
                ),
            ]
        ),

        ConstraintSpec(
            type: .surgePricing,
            category: "Pricing",
            description: "Demand-elastic pricing derived from global demand counters.",
            params: [
                ParamSpec(
                    name: "max_capacity",
                    type: .int,
                    required: true,
                    defaultValue: .int(100),
                    description: "Total call capacity for the measurement window."
                ),
                ParamSpec(
                    name: "window",
                    type: .string,
                    required: false,
                    defaultValue: .string("1h"),
                    description: "Advisory window duration (e.g. 1h, 15m). Server tracks actual demand."
                ),
                ParamSpec(
                    name: "tiers",
                    type: .tiers,
                    required: true,
                    defaultValue: nil,
                    description: "Array of tiers, each with capacity_pct (0-1) and multiplier."
                ),
            ]
        ),

        // ---------------------------------------------------------------
        // MARK: Access constraints
        // ---------------------------------------------------------------

        ConstraintSpec(
            type: .temporalWindow,
            category: "Access",
            description: "Restrict tool access to a configurable time-of-day window.",
            params: [
                ParamSpec(
                    name: "schedule",
                    type: .schedule,
                    required: true,
                    defaultValue: .string("09:00-17:00"),
                    description: "HH:MM-HH:MM time range (24-hour). Wraps midnight when end < start."
                ),
                ParamSpec(
                    name: "timezone",
                    type: .timezone,
                    required: false,
                    defaultValue: .string("UTC"),
                    description: "IANA timezone name (e.g. US/Eastern)."
                ),
            ]
        ),

        ConstraintSpec(
            type: .finiteSupply,
            category: "Access",
            description: "Enforce a finite invocation cap, globally or per-patron.",
            params: [
                ParamSpec(
                    name: "max_invocations",
                    type: .int,
                    required: true,
                    defaultValue: .int(1000),
                    description: "Total allowed invocations."
                ),
                ParamSpec(
                    name: "scope",
                    type: .string,
                    required: false,
                    defaultValue: .string("global"),
                    description: "Scope of the cap: \"global\" or \"per_patron\"."
                ),
            ]
        ),

        ConstraintSpec(
            type: .periodicRefresh,
            category: "Access",
            description: "Rate-limit invocations per rolling time window.",
            params: [
                ParamSpec(
                    name: "max_per_window",
                    type: .int,
                    required: true,
                    defaultValue: .int(100),
                    description: "Maximum invocations allowed per window."
                ),
                ParamSpec(
                    name: "window_duration",
                    type: .string,
                    required: true,
                    defaultValue: .string("PT1H"),
                    description: "ISO-8601 duration string (e.g. PT5H for 5 hours, P1D for 1 day)."
                ),
            ]
        ),

        // ---------------------------------------------------------------
        // MARK: Dynamic constraints
        // ---------------------------------------------------------------

        ConstraintSpec(
            type: .jsonExpression,
            category: "Dynamic",
            description: "Evaluate a safe JSON expression tree against constraint context fields.",
            params: [
                ParamSpec(
                    name: "expression",
                    type: .string,
                    required: true,
                    defaultValue: nil,
                    description: "JSON expression tree with field/op/value leaves and and/or/not combinators."
                ),
                ParamSpec(
                    name: "on_match",
                    type: .string,
                    required: false,
                    defaultValue: .string("allow"),
                    description: "Action when expression matches: \"allow\" or \"deny\"."
                ),
                ParamSpec(
                    name: "deny_reason",
                    type: .string,
                    required: false,
                    defaultValue: .string("expression_denied"),
                    description: "Machine-readable reason code when denying."
                ),
                ParamSpec(
                    name: "deny_message",
                    type: .string,
                    required: false,
                    defaultValue: .string("Constraint expression not satisfied."),
                    description: "Human-readable message when denying."
                ),
            ]
        ),

        // ---------------------------------------------------------------
        // MARK: Identity
        // ---------------------------------------------------------------

        ConstraintSpec(
            type: .patronProof,
            category: "Identity",
            description: "Require the patron to prove npub ownership via Schnorr signature. Use for high-value tools where unauthorized spend must be prevented. The patron signs a Nostr kind-27235 event with their nsec.",
            params: [
                ParamSpec(
                    name: "window_seconds",
                    type: .int,
                    required: false,
                    defaultValue: .int(120),
                    description: "Maximum age of the proof event in seconds."
                ),
            ]
        ),
    ]

    // MARK: - Lookups

    static func spec(for type: PipelineStepType) -> ConstraintSpec? {
        all.first { $0.type == type }
    }

    static var categories: [String] {
        let cats = Set(all.map(\.category))
        return ["Pricing", "Access", "Identity", "Dynamic"].filter { cats.contains($0) }
    }

    static func specs(in category: String) -> [ConstraintSpec] {
        all.filter { $0.category == category }
    }

    /// Generate a prompt-friendly constraint reference for the LLM advisor.
    /// Lists every supported type with its JSON key, category, description,
    /// and parameter specifications so the LLM uses ONLY valid types.
    static var promptReference: String {
        var lines: [String] = [
            "## Supported Constraint Types (EXHAUSTIVE LIST)",
            "",
            "You MUST only use constraint types from this list. Any other type name is INVALID.",
            ""
        ]
        for cat in categories {
            lines.append("### \(cat)")
            for spec in specs(in: cat) {
                lines.append("- **`\(spec.type.rawValue)`**: \(spec.description)")
                let required = spec.params.filter(\.required)
                let optional = spec.params.filter { !$0.required }
                if !required.isEmpty {
                    let paramList = required.map { "  - `\($0.name)` (\($0.type)): \($0.description)" }
                    lines.append("  Required params:")
                    lines.append(contentsOf: paramList)
                }
                if !optional.isEmpty {
                    let paramList = optional.map {
                        let def = $0.defaultValue.map { " (default: \($0))" } ?? ""
                        return "  - `\($0.name)` (\($0.type))\(def): \($0.description)"
                    }
                    lines.append("  Optional params:")
                    lines.append(contentsOf: paramList)
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
