import Foundation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class OperatorCollectionViewModel {

    var showingAddSheet = false
    var selectedOperator: Operator?

    // Edit sheet
    var showingEditSheet = false
    var operatorToEdit: Operator?

    // Delete confirmation
    var showingDeleteConfirmation = false
    var operatorToDelete: Operator?

    // Stats sheet
    var operatorForStats: Operator?

    func addOperator(npub: String, displayName: String, context: ModelContext) {
        let op = Operator(npub: npub, displayName: displayName)
        context.insert(op)
        try? context.save()
        selectedOperator = op
    }

    func updateOperator(_ op: Operator, displayName: String, context: ModelContext) {
        op.displayName = displayName
        try? context.save()
    }

    func deleteOperator(_ op: Operator, context: ModelContext) {
        if selectedOperator?.npub == op.npub {
            selectedOperator = nil
        }
        KeychainService.deleteToken(forOperator: op.npub)
        KeychainService.deleteNsec(forNpub: op.npub)
        context.delete(op)
        try? context.save()
    }

    // MARK: - Sheet / Alert Triggers

    func requestEdit(_ op: Operator) {
        operatorToEdit = op
        showingEditSheet = true
    }

    func requestDelete(_ op: Operator) {
        operatorToDelete = op
        showingDeleteConfirmation = true
    }

    func confirmDelete(context: ModelContext) {
        if let op = operatorToDelete {
            deleteOperator(op, context: context)
        }
        operatorToDelete = nil
        showingDeleteConfirmation = false
    }

    func cancelDelete() {
        operatorToDelete = nil
        showingDeleteConfirmation = false
    }

    func requestStats(_ op: Operator) {
        operatorForStats = op
    }
}
