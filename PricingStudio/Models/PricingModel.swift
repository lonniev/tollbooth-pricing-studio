import CryptoKit
import Foundation

enum PriceType: String, Codable, Sendable, CaseIterable {
    case flat
    case percent
    case formula
}

enum PricingSource: String, Codable, Sendable {
    case stored      // from get_pricing_model (persisted in Neon)
    case synthesized // from tool listing heuristics
}

struct ToolPrice: Codable, Identifiable, Sendable {
    /// DPYC namespace for UUID v5 generation — must match tollbooth-dpyc's DPYC_NAMESPACE.
    private static let dpycNamespace = UUID(uuidString: "d9a3f1c7-4e2b-4a8f-b6d5-1c3e7f9a2b4d")!

    /// Generate a deterministic UUID v5 (SHA-1) from a capability name, matching Python's capability_uuid().
    static func capabilityUUID(_ capability: String) -> String {
        let ns = withUnsafeBytes(of: dpycNamespace.uuid) { Data($0) }
        let hash = Insecure.SHA1.hash(data: ns + Data(capability.utf8))
        var b = Array(hash.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50  // version 5
        b[8] = (b[8] & 0x3F) | 0x80  // variant RFC 4122
        return String(format: "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
                      b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                      b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
    }

    var id: String { toolId }
    let toolId: String
    let toolName: String
    var priceSats: Int
    var priced: Bool
    var priceType: PriceType
    var priceFormula: String?
    var category: String
    let intent: String
    var minCost: Int = 0
    var maxCost: Int? = nil

    init(toolId: String, toolName: String, priceSats: Int, priced: Bool = true, priceType: PriceType = .flat, priceFormula: String? = nil, category: String, intent: String, minCost: Int = 0, maxCost: Int? = nil) {
        precondition(!toolId.isEmpty, "toolId is required for tool '\(toolName)'. Reset the pricing model.")
        self.toolId = toolId
        self.toolName = toolName
        self.priceSats = priceSats
        self.priced = priced
        self.priceType = priceType
        self.priceFormula = priceFormula
        self.category = category
        self.intent = intent
        self.minCost = minCost
        self.maxCost = maxCost
    }

    enum CodingKeys: String, CodingKey {
        case toolId = "tool_id"
        case toolName = "tool_name"
        case priceSats = "price_sats"
        case priced
        case priceType = "price_type"
        case priceFormula = "price_formula"
        case category, intent
        case minCost = "min_cost"
        case maxCost = "max_cost"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toolName = try container.decode(String.self, forKey: .toolName)
        toolId = try container.decode(String.self, forKey: .toolId)
        priceSats = try container.decode(Int.self, forKey: .priceSats)
        priced = try container.decodeIfPresent(Bool.self, forKey: .priced) ?? true  // legacy = priced
        priceType = try container.decodeIfPresent(PriceType.self, forKey: .priceType) ?? .flat
        priceFormula = try container.decodeIfPresent(String.self, forKey: .priceFormula)
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? ""
        intent = try container.decodeIfPresent(String.self, forKey: .intent) ?? ""
        minCost = try container.decodeIfPresent(Int.self, forKey: .minCost) ?? 0
        maxCost = try container.decodeIfPresent(Int.self, forKey: .maxCost)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(toolId, forKey: .toolId)
        try container.encode(toolName, forKey: .toolName)
        try container.encode(priceSats, forKey: .priceSats)
        try container.encode(priced, forKey: .priced)
        try container.encode(priceType, forKey: .priceType)
        try container.encodeIfPresent(priceFormula, forKey: .priceFormula)
        try container.encode(category, forKey: .category)
        try container.encode(intent, forKey: .intent)
        if minCost != 0 {
            try container.encode(minCost, forKey: .minCost)
        }
        if let maxCost {
            try container.encode(maxCost, forKey: .maxCost)
        }
    }
}

struct TrancheLifetime: Codable, Sendable, Equatable {
    var ttlDays: Int?
    var targetUsagePct: Double
    var minDays: Int
    var maxDays: Int

    init(ttlDays: Int? = nil, targetUsagePct: Double = 0.75, minDays: Int = 3, maxDays: Int = 90) {
        if let days = ttlDays {
            self.ttlDays = max(minDays, min(maxDays, days))
        } else {
            self.ttlDays = nil
        }
        self.targetUsagePct = targetUsagePct
        self.minDays = minDays
        self.maxDays = maxDays
    }

    enum CodingKeys: String, CodingKey {
        case ttlDays = "ttl_days"
        case targetUsagePct = "target_usage_pct"
        case minDays = "min_days"
        case maxDays = "max_days"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ttlDays = try container.decodeIfPresent(Int.self, forKey: .ttlDays)
        targetUsagePct = try container.decodeIfPresent(Double.self, forKey: .targetUsagePct) ?? 0.75
        minDays = try container.decodeIfPresent(Int.self, forKey: .minDays) ?? 3
        maxDays = try container.decodeIfPresent(Int.self, forKey: .maxDays) ?? 90
    }

    static let `default` = TrancheLifetime(ttlDays: 15)
}

struct PipelineStep: Codable, Identifiable, Sendable {
    let id: String
    let type: String
    let params: [String: AnyCodableValue]

    var displayType: PipelineStepType {
        PipelineStepType(rawValue: type) ?? .unknown
    }

    static func create(type: String, params: [String: AnyCodableValue] = [:]) -> PipelineStep {
        PipelineStep(id: UUID().uuidString, type: type, params: params)
    }
}

enum PipelineStepType: String, Sendable {
    case temporalWindow = "temporal_window"
    case finiteSupply = "finite_supply"
    case periodicRefresh = "periodic_refresh"
    case coupon
    case freeTrial = "free_trial"
    case loyaltyDiscount = "loyalty_discount"
    case bulkBonus = "bulk_bonus"
    case happyHour = "happy_hour"
    case jsonExpression = "json_expression"
    case surgePricing = "surge_pricing"
    case patronProof = "patron_proof"
    case unknown

    var iconName: String {
        switch self {
        case .temporalWindow: return "clock"
        case .finiteSupply: return "number.circle"
        case .periodicRefresh: return "arrow.clockwise"
        case .coupon: return "ticket"
        case .freeTrial: return "gift"
        case .loyaltyDiscount: return "heart"
        case .bulkBonus: return "shippingbox"
        case .happyHour: return "party.popper"
        case .jsonExpression: return "curlybraces"
        case .surgePricing: return "chart.line.uptrend.xyaxis"
        case .patronProof: return "lock.shield"
        case .unknown: return "questionmark.circle"
        }
    }

    var displayName: String {
        switch self {
        case .temporalWindow: return "Temporal Window"
        case .finiteSupply: return "Finite Supply"
        case .periodicRefresh: return "Periodic Refresh"
        case .coupon: return "Coupon"
        case .freeTrial: return "Free Trial"
        case .loyaltyDiscount: return "Loyalty Discount"
        case .bulkBonus: return "Bulk Bonus"
        case .happyHour: return "Happy Hour"
        case .jsonExpression: return "JSON Expression"
        case .surgePricing: return "Surge Pricing"
        case .patronProof: return "Patron Proof"
        case .unknown: return "Unknown"
        }
    }
}

struct PricingModelResponse: Codable, Sendable {
    let status: String
    let modelId: String?
    let name: String?
    let isActive: Bool?
    let tools: [ToolPrice]?
    let pipeline: [PipelineStep]?
    let trancheLifetime: TrancheLifetime?
    var source: PricingSource = .synthesized

    enum CodingKeys: String, CodingKey {
        case status
        case modelId = "model_id"
        case name
        case isActive = "is_active"
        case tools
        case pipeline
        case trancheLifetime = "tranche_lifetime"
        // source excluded — set programmatically, not from JSON
    }
}

enum AnyCodableValue: Codable, Sendable, CustomStringConvertible {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnyCodableValue])
    case dictionary([String: AnyCodableValue])
    case null

    var description: String {
        switch self {
        case .string(let s): return s
        case .int(let i): return "\(i)"
        case .double(let d): return "\(d)"
        case .bool(let b): return b ? "true" : "false"
        case .array(let a): return "[\(a.map(\.description).joined(separator: ", "))]"
        case .dictionary(let d):
            let pairs = d.map { "\($0.key): \($0.value.description)" }.joined(separator: ", ")
            return "{\(pairs)}"
        case .null: return "null"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let d = try? container.decode([String: AnyCodableValue].self) {
            self = .dictionary(d)
        } else if let a = try? container.decode([AnyCodableValue].self) {
            self = .array(a)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .array(let a): try container.encode(a)
        case .dictionary(let d): try container.encode(d)
        case .null: try container.encodeNil()
        }
    }
}
