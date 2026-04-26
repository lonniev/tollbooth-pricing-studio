import Foundation
import SwiftData

@Model
final class Contact {
    var npub: String = ""
    var displayName: String = ""
    var nip05: String?
    var addedAt: Date = Date()

    init(npub: String, displayName: String, nip05: String? = nil) {
        self.npub = npub
        self.displayName = displayName
        self.nip05 = nip05
        self.addedAt = Date()
    }
}
