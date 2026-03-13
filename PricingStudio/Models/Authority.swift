import Foundation
import SwiftData

@Model
final class Authority {
    @Attribute(.unique) var npub: String
    var displayName: String
    var mcpEndpointURL: String?
    var addedAt: Date
    var isAutoDiscovered: Bool

    init(npub: String, displayName: String, mcpEndpointURL: String? = nil, isAutoDiscovered: Bool = false) {
        self.npub = npub
        self.displayName = displayName
        self.mcpEndpointURL = mcpEndpointURL
        self.addedAt = Date()
        self.isAutoDiscovered = isAutoDiscovered
    }
}
