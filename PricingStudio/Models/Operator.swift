import Foundation
import SwiftData

@Model
final class Operator: PricingTarget {
    @Attribute(.unique) var npub: String
    var displayName: String
    var mcpEndpointURL: String?
    var authorityNpub: String?
    var addedAt: Date

    init(npub: String, displayName: String, mcpEndpointURL: String? = nil, authorityNpub: String? = nil) {
        self.npub = npub
        self.displayName = displayName
        self.mcpEndpointURL = mcpEndpointURL
        self.authorityNpub = authorityNpub
        self.addedAt = Date()
    }
}
