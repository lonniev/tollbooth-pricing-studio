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

    // Duplicate npub rejection
    var showingDuplicateAlert = false
    var duplicateAlertMessage = ""

    func addPatron(npub: String, displayName: String, nsec: String, context: ModelContext) {
        // Reject duplicate npub
        let descriptor = FetchDescriptor<Patron>(predicate: #Predicate { $0.npub == npub })
        if let existing = try? context.fetch(descriptor).first {
            duplicateAlertMessage = "A patron named \"\(existing.displayName)\" already uses this npub. Each patron must have a unique identity."
            showingDuplicateAlert = true
            return
        }

        let patron = Patron(npub: npub, displayName: displayName)
        context.insert(patron)
        try? context.save()
        if !nsec.isEmpty {
            try? KeychainService.saveNsec(nsec, forNpub: npub)
        }
        selectedPatron = patron
    }

    func updatePatron(
        _ patron: Patron,
        displayName: String,
        nsec: String?,
        nip05: String? = nil,
        pictureURL: String? = nil,
        context: ModelContext
    ) {
        patron.displayName = displayName
        patron.nip05 = nip05
        patron.pictureURL = pictureURL

        if let nsec, !nsec.isEmpty {
            // Derive new npub from the updated nsec
            if let newNpub = try? NostrKeyService.npubFromNsec(nsec) {
                let oldNpub = patron.npub
                if newNpub != oldNpub {
                    // Check for collision with existing patron
                    let descriptor = FetchDescriptor<Patron>(predicate: #Predicate { $0.npub == newNpub })
                    let existing = (try? context.fetch(descriptor)) ?? []
                    let others = existing.filter { $0.persistentModelID != patron.persistentModelID }
                    if let conflict = others.first {
                        duplicateAlertMessage = "Cannot change npub — \"\(conflict.displayName)\" already uses that identity."
                        showingDuplicateAlert = true
                        return
                    }

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
