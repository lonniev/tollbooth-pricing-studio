import Foundation

/// Operator-owned discount coupon — one row in the wheel's `coupons` table.
///
/// Mirrors `tollbooth.coupons.models.Coupon.to_dict()` shape.  The
/// `name` field is the catchy code patrons type to redeem; `toolIds`
/// names the tools it discounts — the coupon owns that binding, so a
/// price push never touches it (tollbooth-dpyc 0.98.0).
struct Coupon: Codable, Identifiable, Sendable, Hashable {
    /// The one binding that means *every tool priced above zero*.
    static let everyPaidTool = "*"

    let id: String
    let `operator`: String
    var name: String
    var discountPercent: Double
    var validFrom: Date
    var validUntil: Date
    var usesPerPatron: Int?    // nil = unlimited within window
    var totalUses: Int?        // nil = unlimited
    var timesRedeemed: Int
    var toolIds: [String]      // tool ids, or ["*"]; empty = discounts nothing
    let createdAt: Date?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case `operator`
        case name
        case discountPercent = "discount_percent"
        case validFrom = "valid_from"
        case validUntil = "valid_until"
        case usesPerPatron = "uses_per_patron"
        case totalUses = "total_uses"
        case timesRedeemed = "times_redeemed"
        case toolIds = "tool_ids"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(
        id: String,
        operator: String,
        name: String,
        discountPercent: Double,
        validFrom: Date,
        validUntil: Date,
        usesPerPatron: Int?,
        totalUses: Int?,
        timesRedeemed: Int = 0,
        toolIds: [String] = [],
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.operator = `operator`
        self.name = name
        self.discountPercent = discountPercent
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.usesPerPatron = usesPerPatron
        self.totalUses = totalUses
        self.timesRedeemed = timesRedeemed
        self.toolIds = toolIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        `operator` = try c.decode(String.self, forKey: .operator)
        name = try c.decode(String.self, forKey: .name)
        discountPercent = try c.decode(Double.self, forKey: .discountPercent)
        validFrom = try Coupon.decodeIso8601(c, key: .validFrom)
        validUntil = try Coupon.decodeIso8601(c, key: .validUntil)
        usesPerPatron = try c.decodeIfPresent(Int.self, forKey: .usesPerPatron)
        totalUses = try c.decodeIfPresent(Int.self, forKey: .totalUses)
        timesRedeemed = try c.decodeIfPresent(Int.self, forKey: .timesRedeemed) ?? 0
        toolIds = try c.decodeIfPresent([String].self, forKey: .toolIds) ?? []
        createdAt = try? Coupon.decodeIso8601(c, key: .createdAt)
        updatedAt = try? Coupon.decodeIso8601(c, key: .updatedAt)
    }

    private static func decodeIso8601(
        _ c: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> Date {
        let s = try c.decode(String.self, forKey: key)
        if let d = ISO8601DateFormatter.withFractional.date(from: s) { return d }
        if let d = ISO8601DateFormatter.plain.date(from: s) { return d }
        throw DecodingError.dataCorruptedError(
            forKey: key, in: c,
            debugDescription: "Cannot parse ISO-8601 datetime: \(s)"
        )
    }

    // MARK: - View helpers

    /// `true` when the binding is the wildcard — every tool priced above zero.
    var appliesToEveryPaidTool: Bool {
        toolIds.contains(Self.everyPaidTool)
    }

    /// What this coupon discounts, for the row: "Every paid tool",
    /// "3 tools", or "No tool yet" when nothing is bound.
    var appliesToLabel: String {
        if appliesToEveryPaidTool { return "Every paid tool" }
        switch toolIds.count {
        case 0: return "No tool yet"
        case 1: return "1 tool"
        default: return "\(toolIds.count) tools"
        }
    }

    /// `"3 / 100"` or `"3 / ∞"` for the progress chip.
    var progressLabel: String {
        if let total = totalUses {
            return "\(timesRedeemed) / \(total)"
        }
        return "\(timesRedeemed) / ∞"
    }

    /// `0...1` for ProgressView; `nil` when total cap is unlimited.
    var progressFraction: Double? {
        guard let total = totalUses, total > 0 else { return nil }
        return min(1.0, Double(timesRedeemed) / Double(total))
    }

    /// Window check — `true` if the coupon is currently open for redemption.
    func isInWindow(now: Date = .now) -> Bool {
        now >= validFrom && now < validUntil
    }

    /// `expired` / `not_yet_active` / `total_claimed` / `active` for status chips.
    func status(now: Date = .now) -> Status {
        if now < validFrom { return .notYetActive }
        if now >= validUntil { return .expired }
        if let total = totalUses, timesRedeemed >= total { return .totalClaimed }
        return .active
    }

    enum Status: String, Sendable {
        case active
        case notYetActive = "not_yet_active"
        case expired
        case totalClaimed = "total_claimed"

        var displayLabel: String {
            switch self {
            case .active: "Active"
            case .notYetActive: "Not yet active"
            case .expired: "Expired"
            case .totalClaimed: "Fully claimed"
            }
        }
    }
}

private extension ISO8601DateFormatter {
    nonisolated(unsafe) static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
