import Foundation
import SwiftData

@Model
final class Patron {
    var npub: String = ""
    var displayName: String = ""
    var addedAt: Date = Date()
    /// Deprecated — aliases are no longer supported. Kept for migration compatibility.
    var aliasOf: String?

    init(npub: String, displayName: String) {
        self.npub = npub
        self.displayName = displayName
        self.addedAt = Date()
    }
}
