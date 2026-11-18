import DPYCAuthKit
import Foundation

/// A link a site opens to ask Studio to sign a job's escrow move:
/// `com.tollbooth.dpyc.pricingstudio://escrow?mcp=…&task=…&npub=…&tool=…`.
///
/// It names only where to ask. Studio fetches what waits to be signed from that
/// operator itself, checks each message (`EscrowSigning`) and signs with the key
/// it holds, so a link can never carry a digest to sign.
struct EscrowLink: Identifiable, Equatable, Sendable {
    let mcp: URL
    let taskId: String
    let npub: String

    var id: String { "\(mcp.absoluteString)#\(taskId)#\(npub)" }

    static let scheme = "com.tollbooth.dpyc.pricingstudio"

    /// The link, or nil for anything that is not a well-formed escrow link.
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == "escrow",
              let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String { q.first { $0.name == name }?.value ?? "" }
        guard let mcp = URL(string: value("mcp")), mcp.scheme == "https",
              let host = mcp.host, host.contains("."), mcp.user == nil, mcp.password == nil else { return nil }
        let task = value("task")
        guard (8...64).contains(task.count), task.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        let npub = value("npub")
        guard (try? NostrKeyService.publicKeyHexFromNpub(npub)) != nil else { return nil }
        self.mcp = mcp
        self.taskId = task
        self.npub = npub
    }
}
