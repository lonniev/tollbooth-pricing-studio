import Foundation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class AuthorityCollectionViewModel {

    var showingAddSheet = false
    var selectedAuthority: Authority?

    // Edit sheet
    var showingEditSheet = false
    var authorityToEdit: Authority?

    // Delete confirmation
    var showingDeleteConfirmation = false
    var authorityToDelete: Authority?

    func addAuthority(npub: String, displayName: String, context: ModelContext) {
        let auth = Authority(npub: npub, displayName: displayName)
        context.insert(auth)
        try? context.save()
        selectedAuthority = auth
    }

    func updateAuthority(_ auth: Authority, displayName: String, context: ModelContext) {
        auth.displayName = displayName
        try? context.save()
    }

    func deleteAuthority(_ auth: Authority, context: ModelContext) {
        if selectedAuthority?.npub == auth.npub {
            selectedAuthority = nil
        }
        KeychainService.deleteToken(forOperator: auth.npub)
        KeychainService.deleteTokenBundle(forOperator: auth.npub)
        context.delete(auth)
        try? context.save()
    }

    /// Idempotent upsert — creates the Authority if it doesn't already exist.
    /// Prime is special: it hosts the Oracle, not a tollbooth-authority MCP.
    /// Never write an endpoint into Prime, and never overwrite Prime's display
    /// name from discovery (it has a canonical name).
    func ensureAuthority(npub: String, displayName: String?, endpointURL: String?, context: ModelContext) {
        let isPrime = (npub == Authority.primeNpub)
        let descriptor = FetchDescriptor<Authority>(predicate: #Predicate { $0.npub == npub })
        if let existing = try? context.fetch(descriptor).first {
            // Update endpoint if newly discovered — but never for Prime.
            if !isPrime, let url = endpointURL, existing.mcpEndpointURL == nil {
                existing.mcpEndpointURL = url
                try? context.save()
            }
            return
        }
        let auth = Authority(
            npub: npub,
            displayName: displayName ?? "Authority \(npub.prefix(12))…",
            mcpEndpointURL: isPrime ? nil : endpointURL,
            isAutoDiscovered: true
        )
        context.insert(auth)
        try? context.save()
    }

    // Claim sheet
    var showingClaimSheet = false
    var authorityToClaim: Authority?

    // MARK: - Authority Claim

    enum ClaimStatus: Equatable {
        case idle
        case connecting
        case registering
        case challengeSent
        case confirming
        case awaitingApproval
        case checkingApproval
        case approved(String)
        case denied(String)
        case failed(String)
    }

    var claimStatus: ClaimStatus = .idle

    /// Step 1/3: Initiate the Authority claim protocol by calling `register_authority_npub`.
    func initiateAuthorityClaim(
        authorityEndpoint: URL,
        candidateNpub: String
    ) async {
        claimStatus = .connecting

        let mcpService = MCPService()
        do {
            claimStatus = .registering

            _ = try await mcpService.callRegisterAuthorityNpub(
                endpointURL: authorityEndpoint,
                candidateNpub: candidateNpub
            )

            claimStatus = .challengeSent
        } catch {
            claimStatus = .failed(error.localizedDescription)
        }
    }

    /// Steps 2–3: After the user sends credentials, confirm the claim and check approval.
    func confirmAndCheckApproval(
        authorityEndpoint: URL,
        candidateNpub: String
    ) async {
        let mcpService = MCPService()

        // Step 2: confirm_authority_claim — MCP reads the Nostr stream, verifies reply
        claimStatus = .confirming
        do {
            let confirmResult = try await mcpService.callConfirmAuthorityClaim(
                endpointURL: authorityEndpoint,
                candidateNpub: candidateNpub
            )

            let parsed = Self.parseResponse(confirmResult)
            if !parsed.success {
                claimStatus = .denied(parsed.message)
                return
            }

            claimStatus = .awaitingApproval
        } catch {
            claimStatus = .failed("Claim confirmation failed: \(error.localizedDescription)")
            return
        }

        // Step 3: check_authority_approval — polls for Prime Authority approval
        claimStatus = .checkingApproval
        do {
            let approvalResult = try await mcpService.callCheckAuthorityApproval(
                endpointURL: authorityEndpoint,
                candidateNpub: candidateNpub
            )

            let parsed = Self.parseResponse(approvalResult)
            if parsed.success {
                claimStatus = .approved(parsed.message)
            } else {
                claimStatus = .denied(parsed.message)
            }
        } catch {
            claimStatus = .failed("Approval check failed: \(error.localizedDescription)")
        }
    }

    /// Parse an MCP response that may be JSON with `success` and `error`/`message` fields,
    /// or plain text. Returns a human-readable message and success flag.
    private static func parseResponse(_ text: String) -> (success: Bool, message: String) {
        // Try JSON parsing first
        if let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let success = json["success"] as? Bool ?? false
            let message = (json["message"] as? String)
                ?? (json["error"] as? String)
                ?? (json["detail"] as? String)
                ?? text
            return (success, message)
        }

        // Plain text heuristics
        let lower = text.lowercased()
        let isFailure = lower.contains("denied") || lower.contains("rejected")
            || lower.contains("not approved") || lower.contains("invalid")
            || lower.contains("not found") || lower.contains("no reply")
            || lower.contains("no active")
        return (!isFailure, text)
    }

    func requestClaim(_ auth: Authority) {
        authorityToClaim = auth
        showingClaimSheet = true
        claimStatus = .idle
    }

    // MARK: - Adopt Operator

    enum AdoptionStatus: Equatable {
        case idle
        case registering
        case success(String)
        case failed(String)
        /// Wheel returned `authority_consent_required` — the call needs a
        /// fresh Schnorr identity proof signed by the Authority's npub.
        /// The associated value is the npub that must sign.
        case needsAuthorityProof(npub: String)
        /// Wheel returned `proof_required` / `proof_invalid` / `proof_refresh_needed`
        /// on the operator-side gate. Associated value is the operator npub.
        case needsOperatorProof(npub: String)
        /// Studio is acquiring a proof via the request/receive_npub_proof
        /// Secure Courier handshake against the Authority's MCP.
        case acquiringProof(npub: String, phase: ProofPhase)
    }

    enum ProofPhase: Equatable {
        case sending          // calling request_npub_proof
        case awaitingReply    // waiting on the human to reply in their Nostr client
        case verifying        // calling receive_npub_proof to drain + cache
    }

    var showingAdoptSheet = false
    var adoptionStatus: AdoptionStatus = .idle
    /// proof_token (poison) from the most recent request_npub_proof, threaded
    /// into the matching receive_npub_proof so the wheel can resolve the pin.
    private var pendingProofToken: String = ""

    func requestAdopt(_ auth: Authority) {
        authorityToClaim = auth  // reuse to track which authority
        adoptionStatus = .idle
        showingAdoptSheet = true
    }

    /// Call `register_operator` on the Authority's MCP endpoint to adopt an operator.
    func adoptOperator(
        authority: Authority,
        operatorToAdopt: Operator,
        context: ModelContext
    ) async {
        guard let endpointString = authority.mcpEndpointURL,
              let endpointURL = URL(string: endpointString) else {
            adoptionStatus = .failed("Authority has no MCP endpoint")
            return
        }

        // The Authority's wheel-side register_operator routes through the
        // Oracle, which rejects with "service_url is required" when the
        // operator has no MCP endpoint URL. Catch that locally rather than
        // round-tripping a guaranteed failure to the server. The user is
        // pointed at Edit Operator, which is where the URL gets set.
        let operatorURL = operatorToAdopt.mcpEndpointURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if operatorURL.isEmpty {
            adoptionStatus = .failed(
                "Operator has no MCP endpoint URL. Open Edit Operator and set its public MCP URL " +
                "(e.g. https://my-service.fastmcp.app/mcp) before adopting."
            )
            return
        }

        adoptionStatus = .registering
        let mcpService = MCPService()

        do {
            let result = try await mcpService.callRegisterOperator(
                endpointURL: endpointURL,
                operatorNpub: operatorToAdopt.npub,
                operatorServiceURL: operatorToAdopt.mcpEndpointURL ?? "",
                displayName: operatorToAdopt.displayName,
                authorityNpub: authority.npub
            )
            operatorToAdopt.authorityNpub = authority.npub
            try? context.save()
            adoptionStatus = .success(result)
        } catch let MCPError.structuredError(code, message, extras) {
            // Branch on the wheel's error_code so the UI can surface a remedy
            // flow instead of a dead-end error string. The view layer handles
            // the proof-acquisition handshake; this VM only does state.
            switch code {
            case "authority_consent_required":
                // The wheel includes authority_npub in the payload; prefer
                // that over our local notion in case the Authority MCP runs
                // under an npub we hadn't recorded yet.
                let npub = extras["authority_npub"] ?? authority.npub
                adoptionStatus = .needsAuthorityProof(npub: npub)
            case "proof_required", "proof_invalid", "proof_refresh_needed":
                adoptionStatus = .needsOperatorProof(npub: operatorToAdopt.npub)
            default:
                adoptionStatus = .failed(message)
            }
        } catch {
            adoptionStatus = .failed(error.localizedDescription)
        }
    }

    /// Drive the Secure Courier proof-of-npub handshake for an arbitrary
    /// `npub` against this Authority's MCP, then automatically retry
    /// `adoptOperator`. The receive_npub_proof side-effect persists the
    /// poison-keyed proof_token to Keychain under (`npub`, host), so the
    /// retry's `argsWithProof` picks it up via the cached-token fallback.
    ///
    /// Auto-sign shortcut: if the Studio's Keychain already holds the
    /// `nsec` for this `npub`, skip the DM dance entirely. `argsWithProof`
    /// will produce an inline kind-27235 Schnorr proof from the nsec on
    /// the retry — no relay round-trip needed.
    func acquireProofAndRetryAdopt(
        for npub: String,
        authority: Authority,
        operatorToAdopt: Operator,
        context: ModelContext
    ) async {
        guard let endpointString = authority.mcpEndpointURL,
              let endpointURL = URL(string: endpointString) else {
            adoptionStatus = .failed("Authority has no MCP endpoint")
            return
        }

        if KeychainService.loadNsec(forNpub: npub) != nil {
            // Inline Schnorr tactic — fastest path. argsWithProof handles it.
            await adoptOperator(
                authority: authority,
                operatorToAdopt: operatorToAdopt,
                context: context
            )
            return
        }

        adoptionStatus = .acquiringProof(npub: npub, phase: .sending)
        let mcpService = MCPService()
        do {
            let challenge = try await mcpService.callRequestNpubProof(
                endpointURL: endpointURL,
                patronNpub: npub
            )
            pendingProofToken = challenge.proofToken
            adoptionStatus = .acquiringProof(npub: npub, phase: .awaitingReply)
        } catch {
            adoptionStatus = .failed("Failed to send proof challenge: \(error.localizedDescription)")
        }
    }

    /// Drain the relay for a reply to the proof challenge sent by
    /// `acquireProofAndRetryAdopt`. On success, retry `adoptOperator`.
    func verifyProofAndRetryAdopt(
        for npub: String,
        authority: Authority,
        operatorToAdopt: Operator,
        context: ModelContext
    ) async {
        guard let endpointString = authority.mcpEndpointURL,
              let endpointURL = URL(string: endpointString) else {
            adoptionStatus = .failed("Authority has no MCP endpoint")
            return
        }
        adoptionStatus = .acquiringProof(npub: npub, phase: .verifying)
        let mcpService = MCPService()
        do {
            // callReceiveNpubProof persists the proof_token to Keychain
            // for (npub, host) — argsWithProof will use it on the retry.
            _ = try await mcpService.callReceiveNpubProof(
                endpointURL: endpointURL,
                patronNpub: npub,
                poison: pendingProofToken
            )
            await adoptOperator(
                authority: authority,
                operatorToAdopt: operatorToAdopt,
                context: context
            )
        } catch {
            adoptionStatus = .failed("Verification failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Sheet / Alert Triggers

    func requestEdit(_ auth: Authority) {
        authorityToEdit = auth
        showingEditSheet = true
    }

    func requestDelete(_ auth: Authority) {
        authorityToDelete = auth
        showingDeleteConfirmation = true
    }

    func confirmDelete(context: ModelContext) {
        if let auth = authorityToDelete {
            deleteAuthority(auth, context: context)
        }
        authorityToDelete = nil
        showingDeleteConfirmation = false
    }

    func cancelDelete() {
        authorityToDelete = nil
        showingDeleteConfirmation = false
    }
}
