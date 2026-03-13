import Foundation
import SwiftData

@Model
final class Contact {
    @Attribute(.unique) var npub: String
    var displayName: String
    var addedAt: Date

    init(npub: String, displayName: String) {
        self.npub = npub
        self.displayName = displayName
        self.addedAt = Date()
    }
}
