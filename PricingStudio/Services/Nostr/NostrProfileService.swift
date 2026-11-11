import DPYCAuthKit
import Foundation

// MARK: - kind-0 Profile (NIP-01)

/// NIP-01 kind-0 profile metadata. `picture`/`banner` are public URLs
/// (Iconify SVGs, hosted images) — never bitmap bytes. nil optionals are
/// omitted from the JSON (synthesized `encodeIfPresent`).
struct NostrProfileMetadata: Codable, Sendable, Equatable {
    var name: String? = nil
    var display_name: String? = nil
    var about: String? = nil
    var picture: String? = nil
    var nip05: String? = nil
    var website: String? = nil
    var lud16: String? = nil
    var banner: String? = nil

    /// Trim whitespace and drop empty strings so blank fields don't publish.
    func normalized() -> NostrProfileMetadata {
        func clean(_ s: String?) -> String? {
            let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t?.isEmpty ?? true) ? nil : t
        }
        return NostrProfileMetadata(
            name: clean(name), display_name: clean(display_name), about: clean(about),
            picture: clean(picture), nip05: clean(nip05), website: clean(website),
            lud16: clean(lud16), banner: clean(banner)
        )
    }
}

enum NostrProfileError: LocalizedError {
    case noSigningKey

    var errorDescription: String? {
        switch self {
        case .noSigningKey:
            return "No signing key (nsec) is held for this identity. Profiles are signed by your own key — add the nsec first."
        }
    }
}

/// Read and publish a holder's own Nostr kind-0 profile. Studio signs with the
/// identity's Keychain nsec and publishes straight to relays — self-sovereign,
/// no nsec ever leaves the device, no operator/MCP intermediary. `picture` is a
/// public URL (no image upload).
struct NostrProfileService {
    let relayService: NostrRelayService

    init(relayService: NostrRelayService = NostrRelayService()) {
        self.relayService = relayService
    }

    /// Read the latest kind-0 for `npub` from relays. nil if none / unreachable.
    func fetch(npub: String) async -> NostrProfileMetadata? {
        guard let hex = try? NostrKeyService.publicKeyHexFromNpub(npub) else { return nil }
        guard let event = await relayService.fetchProfileEvent(pubkeyHex: hex),
              let data = event.content.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(NostrProfileMetadata.self, from: data)
    }

    /// Sign a kind-0 with `npub`'s Keychain nsec and publish to relays.
    func publish(npub: String, metadata: NostrProfileMetadata) async throws -> [(URL, Bool, String)] {
        guard let nsec = KeychainService.loadNsec(forNpub: npub) else {
            throw NostrProfileError.noSigningKey
        }
        let privHex = try NostrKeyService.privateKeyHexFromNsec(nsec)
        let pubHex = try NostrKeyService.publicKeyHexFromNpub(npub)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let content = String(
            data: try encoder.encode(metadata.normalized()), encoding: .utf8
        ) ?? "{}"

        let event = try NostrEvent.signed(
            kind: .metadata, content: content, tags: [],
            privateKeyHex: privHex, publicKeyHex: pubHex
        )
        return await relayService.publish(event)
    }

    /// The profile `npub` would carry once it claims `nip05`: the relays' current
    /// kind-0 with `nip05` set and, only where the profile has none, the name
    /// filled from `displayName`. Every other field is kept, because a kind-0
    /// replaces the whole profile.
    static func merged(
        _ current: NostrProfileMetadata?, nip05: String?, displayName: String
    ) -> NostrProfileMetadata {
        var meta = current ?? NostrProfileMetadata()
        meta.nip05 = nip05
        if (meta.name ?? "").isEmpty { meta.name = displayName }
        if (meta.display_name ?? "").isEmpty { meta.display_name = displayName }
        return meta.normalized()
    }

    /// Whether the relays' profile for `npub` already claims `nip05`.
    func claims(npub: String, nip05: String?) async -> Bool {
        let current = await fetch(npub: npub)?.normalized()
        return current?.nip05 == NostrProfileMetadata(nip05: nip05).normalized().nip05
    }

    /// Publish `npub`'s profile claiming `nip05`, signed by its Keychain nsec.
    /// Does nothing when no nsec is held or the relays already match.
    func publishNip05(npub: String, nip05: String?, displayName: String) async throws {
        guard KeychainService.loadNsec(forNpub: npub) != nil else { return }
        let current = await fetch(npub: npub)?.normalized()
        let meta = Self.merged(current, nip05: nip05, displayName: displayName)
        guard meta != current else { return }
        _ = try await publish(npub: npub, metadata: meta)
    }

    /// Fire-and-forget form of `publishNip05` for a sheet's Save.
    static func publishNip05InBackground(npub: String, nip05: String?, displayName: String) {
        Task.detached(priority: .utility) {
            try? await NostrProfileService().publishNip05(
                npub: npub, nip05: nip05, displayName: displayName
            )
        }
    }
}
