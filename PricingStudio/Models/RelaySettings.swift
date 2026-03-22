import Foundation

@MainActor @Observable
class RelaySettings {
    static let shared = RelaySettings()

    nonisolated static let storageKey = "nostr.relays"
    nonisolated static let defaultRelayStrings = [
        "wss://relay.primal.net",
        "wss://nos.lol",
        "wss://relay.0xchat.com",
        "wss://relay.nostr.band",
    ]

    var onRelaysChanged: (([URL]) -> Void)?

    var relays: [String] {
        didSet {
            save()
            onRelaysChanged?(relayURLs)
        }
    }

    var relayURLs: [URL] {
        relays.compactMap { URL(string: $0) }
    }

    private init() {
        if let saved = UserDefaults.standard.stringArray(forKey: Self.storageKey) {
            relays = saved
        } else {
            relays = Self.defaultRelayStrings
        }
    }

    func resetToDefaults() {
        relays = Self.defaultRelayStrings
    }

    private func save() {
        UserDefaults.standard.set(relays, forKey: Self.storageKey)
    }
}
