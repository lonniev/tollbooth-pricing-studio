import Foundation
import SwiftData

@Model
final class Operator: PricingTarget {
    var npub: String = ""
    var displayName: String = ""
    var mcpEndpointURL: String?
    var authorityNpub: String?
    var addedAt: Date = Date()

    /// Display-only: name of the currently deployed campaign (set on deploy).
    var deployedCampaignName: String?

    init(npub: String, displayName: String, mcpEndpointURL: String? = nil, authorityNpub: String? = nil) {
        self.npub = npub
        self.displayName = displayName
        self.mcpEndpointURL = mcpEndpointURL
        self.authorityNpub = authorityNpub
        self.addedAt = Date()
    }
}
