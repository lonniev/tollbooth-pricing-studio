import Foundation
import SwiftData

/// Owner-side review queue for the deferred operator-adoption ("the
/// courtship", wheel 0.45.0). Lists an Authority's pending
/// `request_adoption` rows and lets the owner approve/reject them.
///
/// Approve/reject is a human-consent decision, so it reuses the Secure
/// Courier npub-proof protocol exactly as `AuthorityCollectionViewModel`'s
/// adopt flow does: when the Authority's own consent proof is missing the
/// wheel returns `authority_consent_required`, and this VM drives the same
/// two-tactic handshake — inline Keychain sign when the nsec is held (the
/// Approve click *is* consent), else a `request_npub_proof` →
/// reply-in-Nostr-client → `receive_npub_proof` round-trip — then retries.
@MainActor
@Observable
final class PendingAdoptionsViewModel {

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded([MCPService.AdoptionRequest])
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
    /// poison token from request_npub_proof, threaded into receive_npub_proof.
    private var pendingProofToken: [String: String] = [:]
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
            let rows = try await mcpService.callListAdoptionRequests(
                endpointURL: endpointURL,
                authorityNpub: authorityNpub
            )
            state = .loaded(rows)
        } catch let MCPError.structuredError(code, message, _) {
            // Missing owner consent is a guidance state, not a raw error.
            state = code == "authority_consent_required"
                ? .error("Link this Authority’s nsec to review adoption requests.")
                : .error(message)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Decide

    func decide(
        _ decision: Decision,
        on req: MCPService.AdoptionRequest,
        authority: Authority,
        context: ModelContext
    ) async {
        guard let endpointURL = authority.mcpEndpointURL.flatMap({ URL(string: $0) }) else {
            decisionStatus[req.operatorNpub] = .failed("Authority has no MCP endpoint")
            return
        }

        pendingDecision[req.operatorNpub] = decision
        decisionStatus[req.operatorNpub] = .deciding

        do {
            switch decision {
            case .approve:
                _ = try await mcpService.callApproveAdoption(
                    endpointURL: endpointURL,
                    operatorNpub: req.operatorNpub,
                    authorityNpub: authority.npub
                )
                // Reflect the new registration locally so the connected-
                // operators list updates without a round-trip (best effort).
                flipLocalOperator(req.operatorNpub, to: authority.npub, context: context)
            case .reject(let reason):
                _ = try await mcpService.callRejectAdoption(
                    endpointURL: endpointURL,
                    operatorNpub: req.operatorNpub,
                    authorityNpub: authority.npub,
                    reason: reason
                )
            }
            removeRequest(req.operatorNpub)
            clear(req.operatorNpub)
        } catch let MCPError.structuredError(code, message, extras) {
            switch code {
            case "authority_consent_required":
                // Wheel volunteers authority_npub; prefer it over our record.
                let npub = extras["authority_npub"] ?? authority.npub
                decisionStatus[req.operatorNpub] = .needsAuthorityProof(npub: npub)
            case "adoption_not_found", "adoption_already_provisioned":
                // Stale row — drop it and refresh rather than dead-ending.
                removeRequest(req.operatorNpub)
                clear(req.operatorNpub)
                await load(endpointURL: endpointURL, authorityNpub: authority.npub)
            default:
                decisionStatus[req.operatorNpub] = .failed(message)
            }
        } catch {
            decisionStatus[req.operatorNpub] = .failed(error.localizedDescription)
        }
    }

    // MARK: - Consent proof handshake (reused Secure Courier npub-proof)

    /// Acquire the Authority's consent proof, then retry the pending decision.
    /// Inline Keychain sign when the nsec is held (the click is consent),
    /// else send the DM challenge and wait for the human's reply.
    func acquireProofAndRetry(
        on req: MCPService.AdoptionRequest,
        authority: Authority,
        context: ModelContext
    ) async {
        guard let endpointURL = authority.mcpEndpointURL.flatMap({ URL(string: $0) }) else {
            decisionStatus[req.operatorNpub] = .failed("Authority has no MCP endpoint")
            return
        }

        let npub = consentNpub(for: req.operatorNpub, fallback: authority.npub)

        if KeychainService.loadNsec(forNpub: npub) != nil {
            // Inline Schnorr tactic — makeIdentityProof signs from Keychain on
            // the retry; no DM round-trip needed.
            await retryPendingDecision(on: req, authority: authority, context: context)
            return
        }

        decisionStatus[req.operatorNpub] = .acquiringProof(npub: npub, phase: .sending)
        do {
            let challenge = try await mcpService.callRequestNpubProof(
                endpointURL: endpointURL,
                patronNpub: npub
            )
            pendingProofToken[req.operatorNpub] = challenge.proofToken
            decisionStatus[req.operatorNpub] = .acquiringProof(npub: npub, phase: .awaitingReply)
        } catch {
            decisionStatus[req.operatorNpub] =
                .failed("Failed to send proof challenge: \(error.localizedDescription)")
        }
    }

    /// Drain the relay for the human's reply, caching the poison-keyed proof
    /// token, then retry the pending decision (which now picks up the token).
    func verifyProofAndRetry(
        on req: MCPService.AdoptionRequest,
        authority: Authority,
        context: ModelContext
    ) async {
        guard let endpointURL = authority.mcpEndpointURL.flatMap({ URL(string: $0) }) else {
            decisionStatus[req.operatorNpub] = .failed("Authority has no MCP endpoint")
            return
        }

        let npub = consentNpub(for: req.operatorNpub, fallback: authority.npub)
        decisionStatus[req.operatorNpub] = .acquiringProof(npub: npub, phase: .verifying)
        do {
            _ = try await mcpService.callReceiveNpubProof(
                endpointURL: endpointURL,
                patronNpub: npub,
                poison: pendingProofToken[req.operatorNpub] ?? ""
            )
            await retryPendingDecision(on: req, authority: authority, context: context)
        } catch {
            decisionStatus[req.operatorNpub] =
                .failed("Verification failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func retryPendingDecision(
        on req: MCPService.AdoptionRequest,
        authority: Authority,
        context: ModelContext
    ) async {
        guard let decision = pendingDecision[req.operatorNpub] else {
            clear(req.operatorNpub)
            return
        }
        await decide(decision, on: req, authority: authority, context: context)
    }

    /// The npub whose consent we are gathering — read off the current status
    /// (the wheel may name an Authority npub we hadn't recorded), else the
    /// Authority's own.
    private func consentNpub(for operatorNpub: String, fallback: String) -> String {
        switch decisionStatus[operatorNpub] {
        case .needsAuthorityProof(let npub): return npub
        case .acquiringProof(let npub, _): return npub
        default: return fallback
        }
    }

    private func removeRequest(_ operatorNpub: String) {
        guard case .loaded(var rows) = state else { return }
        rows.removeAll { $0.operatorNpub == operatorNpub }
        state = .loaded(rows)
    }

    private func clear(_ operatorNpub: String) {
        decisionStatus[operatorNpub] = nil
        pendingProofToken[operatorNpub] = nil
        pendingDecision[operatorNpub] = nil
    }

    private func flipLocalOperator(_ operatorNpub: String, to authorityNpub: String, context: ModelContext) {
        let descriptor = FetchDescriptor<Operator>(
            predicate: #Predicate { $0.npub == operatorNpub }
        )
        if let op = (try? context.fetch(descriptor))?.first {
            op.authorityNpub = authorityNpub
            try? context.save()
        }
    }
}
