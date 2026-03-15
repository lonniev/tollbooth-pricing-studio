import Foundation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class PatronCollectionViewModel {

    var showingAddSheet = false
    var selectedPatron: Patron?

    // Edit sheet
    var showingEditSheet = false
    var patronToEdit: Patron?

    // Delete confirmation
    var showingDeleteConfirmation = false
    var patronToDelete: Patron?

    /// Set by AddPatronSheet when a duplicate npub is detected; triggers alias confirmation alert.
    var pendingAlias: PendingAlias?
    var showingAliasConfirmation = false

    struct PendingAlias {
        let npub: String
        let displayName: String
        let nsec: String
        let existingName: String
    }

    func addPatron(npub: String, displayName: String, nsec: String, context: ModelContext) {
        // Check for existing patron with same npub
        let descriptor = FetchDescriptor<Patron>(predicate: #Predicate { $0.npub == npub })
        if let existing = try? context.fetch(descriptor).first {
            // Duplicate detected — ask user to confirm alias
            pendingAlias = PendingAlias(
                npub: npub,
                displayName: displayName,
                nsec: nsec,
                existingName: existing.displayName
            )
            showingAliasConfirmation = true
            return
        }

        insertPatron(npub: npub, displayName: displayName, nsec: nsec, aliasOf: nil, context: context)
    }

    func confirmAlias(context: ModelContext) {
        guard let alias = pendingAlias else { return }
        insertPatron(
            npub: alias.npub,
            displayName: alias.displayName,
            nsec: alias.nsec,
            aliasOf: alias.existingName,
            context: context
        )
        pendingAlias = nil
        showingAliasConfirmation = false
    }

    func cancelAlias() {
        pendingAlias = nil
        showingAliasConfirmation = false
    }

    private func insertPatron(npub: String, displayName: String, nsec: String, aliasOf: String?, context: ModelContext) {
        let patron = Patron(npub: npub, displayName: displayName, aliasOf: aliasOf)
        context.insert(patron)
        try? context.save()
        try? KeychainService.saveNsec(nsec, forNpub: npub)
        selectedPatron = patron
    }

    func updatePatron(_ patron: Patron, displayName: String, nsec: String?, context: ModelContext) {
        patron.displayName = displayName

        if let nsec, !nsec.isEmpty {
            // Derive new npub from the updated nsec
            if let newNpub = try? NostrKeyService.npubFromNsec(nsec) {
                // Move keychain entries if npub changed
                let oldNpub = patron.npub
                if newNpub != oldNpub {
                    KeychainService.deleteNsec(forNpub: oldNpub)
                    patron.npub = newNpub
                }
            }
            try? KeychainService.saveNsec(nsec, forNpub: patron.npub)
        }

        try? context.save()
    }

    func deletePatron(_ patron: Patron, context: ModelContext) {
        if selectedPatron?.npub == patron.npub {
            selectedPatron = nil
        }
        KeychainService.deleteNsec(forNpub: patron.npub)
        context.delete(patron)
        try? context.save()
    }

    // MARK: - Sheet / Alert Triggers

    func requestEdit(_ patron: Patron) {
        patronToEdit = patron
        showingEditSheet = true
    }

    func requestDelete(_ patron: Patron) {
        patronToDelete = patron
        showingDeleteConfirmation = true
    }

    func confirmDelete(context: ModelContext) {
        if let patron = patronToDelete {
            deletePatron(patron, context: context)
        }
        patronToDelete = nil
        showingDeleteConfirmation = false
    }

    func cancelDelete() {
        patronToDelete = nil
        showingDeleteConfirmation = false
    }
}
