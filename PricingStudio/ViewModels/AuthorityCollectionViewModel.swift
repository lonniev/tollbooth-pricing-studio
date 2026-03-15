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
        case failed(String)
    }

    var claimStatus: ClaimStatus = .idle

    /// Initiate the Authority claim protocol by calling `register_authority_npub`
    /// on the Authority's MCP endpoint. The Authority will send a challenge DM
    /// to the candidate npub via the Secure Courier channel.
    func initiateAuthorityClaim(
        authorityEndpoint: URL,
        candidateNpub: String,
        bearerToken: String
    ) async {
        claimStatus = .connecting

        let mcpService = MCPService()
        do {
            claimStatus = .registering

            let result = try await mcpService.callRegisterAuthorityNpub(
                endpointURL: authorityEndpoint,
                bearerToken: bearerToken,
                candidateNpub: candidateNpub
            )

            if result.contains("challenge") || result.contains("sent") || result.contains("ok") {
                claimStatus = .challengeSent
            } else {
                claimStatus = .challengeSent
            }
        } catch {
            claimStatus = .failed(error.localizedDescription)
        }
    }

    func requestClaim(_ auth: Authority) {
        authorityToClaim = auth
        showingClaimSheet = true
        claimStatus = .idle
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
