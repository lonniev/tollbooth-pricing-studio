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
