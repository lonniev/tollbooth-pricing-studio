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

    // Campaign slots
    var selectedCampaign: Campaign?
    var campaignsForCompare: Set<PersistentIdentifier> = []
    var showingCompareFromSidebar = false
    var deployedCampaignJSON: String?

    // Campaign delete confirmation
    var showingCampaignDeleteConfirmation = false
    var campaignToDelete: Campaign?

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

    // MARK: - Campaign Slots

    /// Deploy a campaign: mark it as live, clear siblings, and bridge the pipeline JSON.
    func deployCampaign(_ campaign: Campaign, for op: Operator, context: ModelContext) {
        // Clear deployed flag on all sibling campaigns
        let opNpub = op.npub
        let descriptor = FetchDescriptor<Campaign>(predicate: #Predicate { $0.operatorNpub == opNpub })
        if let siblings = try? context.fetch(descriptor) {
            for sibling in siblings {
                sibling.isDeployed = (sibling.persistentModelID == campaign.persistentModelID)
            }
        }

        op.deployedCampaignName = campaign.name
        deployedCampaignJSON = campaign.proposal?.pipelineJSON
        try? context.save()
    }

    /// Request deletion of a campaign (shows confirmation alert).
    func requestCampaignDelete(_ campaign: Campaign) {
        campaignToDelete = campaign
        showingCampaignDeleteConfirmation = true
    }

    /// Confirm and delete the campaign from SwiftData.
    func confirmCampaignDelete(context: ModelContext) {
        if let campaign = campaignToDelete {
            // Remove from compare queue if present
            campaignsForCompare.remove(campaign.persistentModelID)
            // Clear selection if this was the active campaign
            if selectedCampaign?.persistentModelID == campaign.persistentModelID {
                selectedCampaign = nil
            }
            context.delete(campaign)
            try? context.save()
        }
        campaignToDelete = nil
        showingCampaignDeleteConfirmation = false
    }

    /// Cancel campaign deletion.
    func cancelCampaignDelete() {
        campaignToDelete = nil
        showingCampaignDeleteConfirmation = false
    }

    /// Toggle a campaign in/out of the compare set (max 3).
    func toggleCompare(_ campaign: Campaign) {
        let id = campaign.persistentModelID
        if campaignsForCompare.contains(id) {
            campaignsForCompare.remove(id)
        } else if campaignsForCompare.count < 3 {
            campaignsForCompare.insert(id)
        }
    }
}
