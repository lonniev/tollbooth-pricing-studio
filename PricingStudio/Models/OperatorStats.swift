import Foundation

struct OperatorStats: Sendable {
    let registryRole: String
    let registryStatus: String
    let registryDisplayName: String
    let services: [MemberService]
    let totalToolCount: Int
    let freeToolCount: Int
    let paidToolCount: Int
    let categorySummaries: [ToolCategorySummary]
    let versions: [String: String]?
    let fetchedAt: Date
}

struct ToolCategorySummary: Identifiable, Sendable {
    var id: String { category }
    let category: String
    let count: Int
    let minPriceSats: Int
    let maxPriceSats: Int
}
