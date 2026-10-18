import Foundation
import SwiftData

/// Owner-side review queue of an Authority's pending operator requests:
/// adoptions, and updates to an operator's registry entry. The owner
/// approves or rejects each.
///
/// The Authority acts, so the connection must prove its npub: signed with
/// the Keychain nsec when Studio holds it (the Approve click *is* consent),
/// else the wheel returns `authority_consent_required` and this VM drives a
/// `request_npub_proof` → reply-in-Nostr-client → `receive_npub_proof`
/// round-trip into the holder connection, then retries.
@MainActor
@Observable
final class PendingAdoptionsViewModel {

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded([MCPService.OperatorRequest])
        case error(String)
    }

    /// The owner's verdict on a single request.
    enum Decision: Equatable {
        case approve
        case reject(reason: String)
    }

    /// Per-request status of an in-flight or stalled decision. A request with
    /// no entry is idle (its row shows plain Approve/Reject actions).
    enum DecisionStatus: Equatable {
        case deciding
        case needsAuthorityProof(npub: String)
        case acquiringProof(npub: String, phase: AuthorityCollectionViewModel.ProofPhase)
        case failed(String)
    }

    private(set) var state: LoadState = .idle
    private(set) var decisionStatus: [String: DecisionStatus] = [:]

    private let mcpService = MCPService()
    /// nonce token from request_npub_proof, threaded into receive_npub_proof.
    private var pendingNonce: [String: String] = [:]
    /// the decision to retry once the consent proof is acquired.
    private var pendingDecision: [String: Decision] = [:]

    var pendingCount: Int {
        if case .loaded(let rows) = state { return rows.count }
        return 0
    }

    // MARK: - Load

    func load(endpointURL: URL, authorityNpub: String) async {
        state = .loading
        do {
            let rows = try await mcpService.callListOperatorRequests(
                endpointURL: endpointURL,
                authorityNpub: authorityNpub
            )
            state = .loaded(rows)
        } catch let MCPError.structuredError(code, message, _) {
            // Missing owner consent is a guidance state, not a raw error.
            state = code == "authority_consent_required"
                ? .error("Link this Authority’s nsec to review operator requests.")
                : .error(message)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Decide

    func decide(
        _ decision: Decision,
        on req: MCPService.OperatorRequest,
        authority: Authority,
        context: ModelContext
    ) async {
        guard let endpointURL = authority.mcpEndpointURL.flatMap({ URL(string: $0) }) else {
            decisionStatus[req.id] = .failed("Authority has no MCP endpoint")
            return
        }

        pendingDecision[req.id] = decision
        decisionStatus[req.id] = .deciding

        do {
            switch decision {
            case .approve:
                _ = try await mcpService.callApproveOperatorRequest(
                    endpointURL: endpointURL,
                    operatorNpub: req.operatorNpub,
                    kind: req.kind,
                    authorityNpub: authority.npub
                )
                // Reflect the approval locally so the connected-operators
                // list updates without a round-trip (best effort).
                applyLocally(req, authorityNpub: authority.npub, context: context)
            case .reject(let reason):
                _ = try await mcpService.callRejectOperatorRequest(
                    endpointURL: endpointURL,
                    operatorNpub: req.operatorNpub,
                    kind: req.kind,
                    authorityNpub: authority.npub,
                    reason: reason
                )
            }
            removeRequest(req.id)
            clear(req.id)
        } catch let MCPError.structuredError(code, message, extras) {
            switch code {
            case "authority_consent_required":
                // Wheel volunteers authority_npub; prefer it over our record.
                let npub = extras["authority_npub"] ?? authority.npub
                decisionStatus[req.id] = .needsAuthorityProof(npub: npub)
            case "adoption_not_found", "adoption_already_provisioned":
                // Stale row — drop it and refresh rather than dead-ending.
                removeRequest(req.id)
                clear(req.id)
                await load(endpointURL: endpointURL, authorityNpub: authority.npub)
            default:
                decisionStatus[req.id] = .failed(message)
            }
        } catch {
            decisionStatus[req.id] = .failed(error.localizedDescription)
        }
    }

    // MARK: - Consent proof handshake (reused Secure Courier npub-proof)

    /// Acquire the Authority's consent proof, then retry the pending decision.
    /// Inline Keychain sign when the nsec is held (the click is consent),
    /// else send the DM challenge and wait for the human's reply.
    func acquireProofAndRetry(
        on req: MCPService.OperatorRequest,
        authority: Authority,
        context: ModelContext
    ) async {
        guard let endpointURL = authority.mcpEndpointURL.flatMap({ URL(string: $0) }) else {
            decisionStatus[req.id] = .failed("Authority has no MCP endpoint")
            return
        }

        let npub = consentNpub(for: req.id, fallback: authority.npub)

        if KeychainService.loadNsec(forNpub: npub) != nil {
            // Studio holds the key: the retry signs with it, no DM needed.
            await retryPendingDecision(on: req, authority: authority, context: context)
            return
        }

        decisionStatus[req.id] = .acquiringProof(npub: npub, phase: .sending)
        do {
            let challenge = try await mcpService.callRequestNpubProof(
                endpointURL: endpointURL,
                patronNpub: npub
            )
            pendingNonce[req.id] = challenge.nonce
            decisionStatus[req.id] = .acquiringProof(npub: npub, phase: .awaitingReply)
        } catch {
            decisionStatus[req.id] =
                .failed("Failed to send proof challenge: \(error.localizedDescription)")
        }
    }

    /// Drain the relay for the human's reply into the holder connection,
    /// then retry the pending decision on it.
    func verifyProofAndRetry(
        on req: MCPService.OperatorRequest,
        authority: Authority,
        context: ModelContext
    ) async {
        guard let endpointURL = authority.mcpEndpointURL.flatMap({ URL(string: $0) }) else {
            decisionStatus[req.id] = .failed("Authority has no MCP endpoint")
            return
        }

        let npub = consentNpub(for: req.id, fallback: authority.npub)
        decisionStatus[req.id] = .acquiringProof(npub: npub, phase: .verifying)
        do {
            _ = try await mcpService.callReceiveNpubProof(
                endpointURL: endpointURL,
                patronNpub: npub,
                nonce: pendingNonce[req.id] ?? ""
            )
            await retryPendingDecision(on: req, authority: authority, context: context)
        } catch {
            decisionStatus[req.id] =
                .failed("Verification failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func retryPendingDecision(
        on req: MCPService.OperatorRequest,
        authority: Authority,
        context: ModelContext
    ) async {
        guard let decision = pendingDecision[req.id] else {
            clear(req.id)
            return
        }
        await decide(decision, on: req, authority: authority, context: context)
    }

    /// The npub whose consent we are gathering — read off the current status
    /// (the wheel may name an Authority npub we hadn't recorded), else the
    /// Authority's own.
    private func consentNpub(for requestID: String, fallback: String) -> String {
        switch decisionStatus[requestID] {
        case .needsAuthorityProof(let npub): return npub
        case .acquiringProof(let npub, _): return npub
        default: return fallback
        }
    }

    private func removeRequest(_ requestID: String) {
        guard case .loaded(var rows) = state else { return }
        rows.removeAll { $0.id == requestID }
        state = .loaded(rows)
    }

    private func clear(_ requestID: String) {
        decisionStatus[requestID] = nil
        pendingNonce[requestID] = nil
        pendingDecision[requestID] = nil
    }

    /// An approved adoption links the operator to this Authority; an approved
    /// update takes its new service URL and name.
    private func applyLocally(_ req: MCPService.OperatorRequest, authorityNpub: String, context: ModelContext) {
        let operatorNpub = req.operatorNpub
        let descriptor = FetchDescriptor<Operator>(
            predicate: #Predicate { $0.npub == operatorNpub }
        )
        guard let op = (try? context.fetch(descriptor))?.first else { return }
        if req.isUpdate {
            if !req.serviceURL.isEmpty { op.mcpEndpointURL = req.serviceURL }
            if !req.displayName.isEmpty { op.displayName = req.displayName }
        } else {
            op.authorityNpub = authorityNpub
        }
        try? context.save()
    }
}
