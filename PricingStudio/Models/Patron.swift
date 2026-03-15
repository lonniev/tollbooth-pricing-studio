import Foundation
import SwiftData

@Model
final class Patron {
    var npub: String = ""
    var displayName: String = ""
    var addedAt: Date = Date()
    /// Non-nil when this patron is an alias of another identity sharing the same npub.
    var aliasOf: String?

    init(npub: String, displayName: String, aliasOf: String? = nil) {
        self.npub = npub
        self.displayName = displayName
        self.addedAt = Date()
        self.aliasOf = aliasOf
    }
}
