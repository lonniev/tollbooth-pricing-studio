import Foundation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class OperatorCollectionViewModel {

    var showingAddSheet = false
    var selectedOperator: Operator?

    func addOperator(npub: String, displayName: String, context: ModelContext) {
        let op = Operator(npub: npub, displayName: displayName)
        context.insert(op)
        try? context.save()
        selectedOperator = op
    }

    func deleteOperator(_ op: Operator, context: ModelContext) {
        if selectedOperator?.npub == op.npub {
            selectedOperator = nil
        }
        KeychainService.deleteToken(forOperator: op.npub)
        context.delete(op)
        try? context.save()
    }
}
