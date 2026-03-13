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

    func addPatron(npub: String, displayName: String, nsec: String, context: ModelContext) {
        let patron = Patron(npub: npub, displayName: displayName)
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
