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
    func ensureAuthority(npub: String, displayName: String?, endpointURL: String?, context: ModelContext) {
        let descriptor = FetchDescriptor<Authority>(predicate: #Predicate { $0.npub == npub })
        if let existing = try? context.fetch(descriptor).first {
            // Update endpoint if newly discovered
            if let url = endpointURL, existing.mcpEndpointURL == nil {
                existing.mcpEndpointURL = url
                try? context.save()
            }
            return
        }
        let auth = Authority(
            npub: npub,
            displayName: displayName ?? "Authority \(npub.prefix(12))…",
            mcpEndpointURL: endpointURL,
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
        candidateNpub: String,
        bearerToken: String
    ) async {
        claimStatus = .connecting

        let mcpService = MCPService()
        do {
            claimStatus = .registering

            _ = try await mcpService.callRegisterAuthorityNpub(
                endpointURL: authorityEndpoint,
                bearerToken: bearerToken,
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
        candidateNpub: String,
        bearerToken: String
    ) async {
        let mcpService = MCPService()

        // Step 2: confirm_authority_claim — MCP reads the Nostr stream, verifies reply
        claimStatus = .confirming
        do {
            let confirmResult = try await mcpService.callConfirmAuthorityClaim(
                endpointURL: authorityEndpoint,
                bearerToken: bearerToken,
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
                bearerToken: bearerToken,
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
    }

    var showingAdoptSheet = false
    var adoptionStatus: AdoptionStatus = .idle

    func requestAdopt(_ auth: Authority) {
        authorityToClaim = auth  // reuse to track which authority
        adoptionStatus = .idle
        showingAdoptSheet = true
    }

    /// Call `register_operator` on the Authority's MCP endpoint to adopt an operator.
    func adoptOperator(
        authority: Authority,
        operatorToAdopt: Operator,
        bearerToken: String,
        context: ModelContext
    ) async {
        guard let endpointString = authority.mcpEndpointURL,
              let endpointURL = URL(string: endpointString) else {
            adoptionStatus = .failed("Authority has no MCP endpoint")
            return
        }

        adoptionStatus = .registering
        let mcpService = MCPService()

        do {
            let result = try await mcpService.callRegisterOperator(
                endpointURL: endpointURL,
                bearerToken: bearerToken,
                operatorNpub: operatorToAdopt.npub,
                operatorServiceURL: operatorToAdopt.mcpEndpointURL ?? ""
            )
            operatorToAdopt.authorityNpub = authority.npub
            try? context.save()
            adoptionStatus = .success(result)
        } catch {
            adoptionStatus = .failed(error.localizedDescription)
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
