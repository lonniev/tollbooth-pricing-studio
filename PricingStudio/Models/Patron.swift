import Foundation
import SwiftData

@Model
final class Patron {
    var npub: String = ""
    var displayName: String = ""
    var nip05: String?
    var addedAt: Date = Date()
    /// Deprecated — aliases are no longer supported. Kept for migration compatibility.
    var aliasOf: String?

    init(npub: String, displayName: String, nip05: String? = nil) {
        self.npub = npub
        self.displayName = displayName
        self.nip05 = nip05
        self.addedAt = Date()
    }
}
