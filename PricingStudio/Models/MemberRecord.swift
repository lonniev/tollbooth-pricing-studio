import Foundation

/// Wrapper for Oracle lookup_member response: {"result": <MemberRecord or String>}
struct OracleLookupResponse: Codable, Sendable {
    let result: OracleResult

    enum OracleResult: Codable, Sendable {
        case member(MemberRecord)
        case message(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let record = try? container.decode(MemberRecord.self) {
                self = .member(record)
            } else if let msg = try? container.decode(String.self) {
                self = .message(msg)
            } else {
                throw DecodingError.typeMismatch(
                    OracleResult.self,
                    .init(codingPath: decoder.codingPath, debugDescription: "Expected MemberRecord or String")
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .member(let record): try container.encode(record)
            case .message(let msg): try container.encode(msg)
            }
        }
    }
}

struct MemberRecord: Codable, Sendable {
    let npub: String
    let role: String
    let status: String
    let displayName: String
    let services: [MemberService]?
    let upstreamAuthorityNpub: String?
    let memberSince: String?
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case npub
        case role
        case status
        case displayName = "display_name"
        case services
        case upstreamAuthorityNpub = "upstream_authority_npub"
        case memberSince = "member_since"
        case notes
    }

    var mcpEndpointURL: String? {
        services?.first?.url
    }
}

struct MemberService: Codable, Sendable {
    let name: String
    let url: String
    let description: String?
}
