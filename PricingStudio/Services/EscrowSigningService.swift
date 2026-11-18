import DPYCAuthKit
import Foundation
import LocalAuthentication
import MCP

/// Reads what a job's escrow waits on from this npub, and signs it with the
/// nsec the Keychain holds, after the device owner confirms.
///
/// Every request is signed NIP-98 by the npub itself (`MCPService.Caller.npub`),
/// and every message is rebuilt and checked by `EscrowSigning` before its
/// digest is signed.
enum EscrowSigningService {

    /// One move waiting on this npub, with the most it may pay out.
    struct Pending: Identifiable, Sendable {
        let item: EscrowSigning.Signable
        let most: Int
        var id: String { item.sign_digest }
    }

    struct Reading: Sendable {
        let title: String
        let state: String
        let mint: String
        let pending: [Pending]
    }

    enum Failure: LocalizedError {
        case noKey, refused(String), cancelled

        var errorDescription: String? {
            switch self {
            case .noKey: return "Pricing Studio holds no key for this npub."
            case .refused(let why): return why
            case .cancelled: return "Signing was cancelled."
            }
        }
    }

    private static func json(_ text: String) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw Failure.refused("The operator gave no readable answer.")
        }
        if obj["ok"] as? Bool == false || obj["success"] as? Bool == false {
            throw Failure.refused((obj["error"] as? String) ?? "The operator refused.")
        }
        return obj
    }

    private static func call(_ link: EscrowLink, _ tool: String, _ args: [String: Value] = [:]) async throws -> [String: Any] {
        var arguments = args
        arguments["task_id"] = .string(link.taskId)
        arguments["npub"] = .string(link.npub)
        let text = try await MCPService().callToolGeneric(endpointURL: link.mcp, toolName: tool, arguments: arguments,
                                                          as: .npub(link.npub))
        return try json(text)
    }

    /// The job's title, where its escrow stands, and each move waiting on this npub.
    static func read(_ link: EscrowLink) async throws -> Reading {
        guard OperatorProofService.holdsKey(for: link.npub) else { throw Failure.noKey }
        let status = try await call(link, "escrow_status")
        let task = (try? await call(link, "get_task"))?["task"] as? [String: Any]
        let escrow = status["escrow"] as? [String: Any] ?? [:]
        let forYou = status["for_you"] as? [[String: Any]] ?? []
        let pending: [Pending] = forYou.compactMap { raw in
            guard let data = try? JSONSerialization.data(withJSONObject: raw),
                  let item = try? JSONDecoder().decode(EscrowSigning.Signable.self, from: data) else { return nil }
            return Pending(item: item, most: most(for: item, escrow: escrow))
        }
        return Reading(title: task?["title"] as? String ?? link.taskId, state: escrow["state"] as? String ?? "",
                       mint: escrow["mint"] as? String ?? "", pending: pending)
    }

    /// The most a move may pay out, which the rebuilt message must stay within.
    static func most(for item: EscrowSigning.Signable, escrow: [String: Any]) -> Int {
        switch item.what {
        case .fund: return escrow["sats"] as? Int ?? 0
        case .proposal: return escrow["held_sats"] as? Int ?? 0
        case .collect: return (escrow["to_collect"] as? [String: Int])?[item.role ?? ""] ?? 0
        }
    }

    /// Check, confirm with the device owner, sign, and hand the signature to the operator.
    static func sign(_ pending: Pending, link: EscrowLink, reason: String) async throws {
        do {
            _ = try EscrowSigning.checkedDigest(pending.item, npub: link.npub, most: pending.most)
        } catch {
            throw Failure.refused(error.localizedDescription)
        }
        let context = LAContext()
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else {
                throw Failure.cancelled
            }
        } catch {
            throw Failure.cancelled
        }
        guard let nsec = KeychainService.loadNsec(forNpub: link.npub) else { throw Failure.noKey }
        let signature = try EscrowSigning.sign(pending.item, npub: link.npub, most: pending.most,
                                               privateKeyHex: try NostrKeyService.privateKeyHexFromNsec(nsec))
        _ = try await call(link, "escrow_sign", ["signature": .string(signature)])
    }
}
