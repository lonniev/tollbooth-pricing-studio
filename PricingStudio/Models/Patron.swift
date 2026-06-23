import Foundation
import SwiftData

@Model
final class Patron {
    var npub: String = ""
    var displayName: String = ""
    var nip05: String?
    /// Cached Nostr kind-0 avatar URL (Iconify SVG / hosted image / emoji), so the
    /// patron's avatar renders everywhere without re-reading relays. Set when the
    /// Patron Edit dialog publishes the profile.
    var pictureURL: String?
    var addedAt: Date = Date()
    /// Deprecated — aliases are no longer supported. Kept for migration compatibility.
    var aliasOf: String?

    init(npub: String, displayName: String, nip05: String? = nil, pictureURL: String? = nil) {
        self.npub = npub
        self.displayName = displayName
        self.nip05 = nip05
        self.pictureURL = pictureURL
        self.addedAt = Date()
    }
}
