import Foundation
import SwiftData

@Model
final class Contact {
    var npub: String = ""
    var displayName: String = ""
    var addedAt: Date = Date()

    init(npub: String, displayName: String) {
        self.npub = npub
        self.displayName = displayName
        self.addedAt = Date()
    }
}
