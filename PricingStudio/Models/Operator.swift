import Foundation
import SwiftData

@Model
final class Operator {
    @Attribute(.unique) var npub: String
    var displayName: String
    var mcpEndpointURL: String?
    var addedAt: Date

    init(npub: String, displayName: String, mcpEndpointURL: String? = nil) {
        self.npub = npub
        self.displayName = displayName
        self.mcpEndpointURL = mcpEndpointURL
        self.addedAt = Date()
    }
}
