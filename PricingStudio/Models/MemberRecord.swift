import Foundation

struct MemberRecord: Codable, Sendable {
    let npub: String
    let role: String
    let status: String
    let displayName: String
    let services: [MemberService]?

    enum CodingKeys: String, CodingKey {
        case npub
        case role
        case status
        case displayName = "display_name"
        case services
    }

    var mcpEndpointURL: String? {
        services?.first(where: { $0.type == "mcp" })?.url
    }
}

struct MemberService: Codable, Sendable {
    let name: String
    let type: String
    let url: String
}
