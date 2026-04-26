import Foundation
import SwiftData

@Model
final class Operator: PricingTarget {
    var npub: String = ""
    var displayName: String = ""
    var nip05: String?
    var mcpEndpointURL: String?
    var authorityNpub: String?
    var addedAt: Date = Date()

    /// Display-only: name of the currently deployed campaign (set on deploy).
    var deployedCampaignName: String?

    init(npub: String, displayName: String, nip05: String? = nil, mcpEndpointURL: String? = nil, authorityNpub: String? = nil) {
        self.npub = npub
        self.displayName = displayName
        self.nip05 = nip05
        self.mcpEndpointURL = mcpEndpointURL
        self.authorityNpub = authorityNpub
        self.addedAt = Date()
    }
}
