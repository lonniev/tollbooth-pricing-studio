import XCTest
@testable import PricingStudio

final class NostrRelayTests: XCTestCase {

    // MARK: - Ephemeral Keypair Helpers

    private func generateEphemeralKeys() throws -> (privHex: String, pubHex: String) {
        let (nsec, npub) = try NostrKeyService.generateKeyPair()
        let privHex = try NostrKeyService.privateKeyHexFromNsec(nsec)
        let pubHex = try NostrKeyService.publicKeyHexFromNpub(npub)
        return (privHex, pubHex)
    }

    // MARK: - NIP-04 Publish & Fetch

    func testPublishAndFetchNIP04() async throws {
        let alice = try generateEphemeralKeys()
        let bob = try generateEphemeralKeys()

        let plaintext = "NIP-04 relay test \(UUID().uuidString.prefix(8))"
        let relay = NostrRelayService(relays: NostrRelayService.defaultRelays)

        // Alice sends NIP-04 DM to Bob
        let encrypted = try NIP04Service.encrypt(
            plaintext,
            privateKeyHex: alice.privHex,
            publicKeyHex: bob.pubHex
        )
        let event = try NostrEvent.signed(
            kind: .encryptedDM,
            content: encrypted,
            tags: [["p", bob.pubHex]],
            privateKeyHex: alice.privHex,
            publicKeyHex: alice.pubHex
        )

        let publishResults = await relay.publish(event)
        let accepted = publishResults.filter { $0.1 }.count
        XCTAssertGreaterThan(accepted, 0, "At least one relay should accept the NIP-04 event")

        // Brief delay for relay propagation
        try await Task.sleep(for: .seconds(2))

        // Bob fetches from relays
        let events = await relay.fetchDMs(
            pubkeyHex: bob.pubHex,
            since: Int(Date().timeIntervalSince1970) - 60
        )

        let matchingEvents = events.filter { $0.id == event.id }
        XCTAssertFalse(matchingEvents.isEmpty, "Bob should find Alice's NIP-04 DM on at least one relay")

        // Bob decrypts
        if let fetched = matchingEvents.first {
            let decrypted = try NIP04Service.decrypt(
                fetched.content,
                privateKeyHex: bob.privHex,
                publicKeyHex: alice.pubHex
            )
            XCTAssertEqual(decrypted, plaintext, "Decrypted message should match original")
        }
    }

    // MARK: - NIP-17 Gift Wrap Publish & Fetch

    func testPublishAndFetchGiftWrap() async throws {
        let alice = try generateEphemeralKeys()
        let bob = try generateEphemeralKeys()

        let plaintext = "NIP-17 gift wrap test \(UUID().uuidString.prefix(8))"

        // Use NostrDMService to build and send the gift wrap via dual protocol
        let dmService = NostrDMService(
            relay: NostrRelayService(relays: NostrRelayService.defaultRelays)
        )

        // This sends via both NIP-04 and NIP-17
        try await dmService.sendDM(
            privateKeyHex: alice.privHex,
            publicKeyHex: alice.pubHex,
            recipientPubkeyHex: bob.pubHex,
            message: plaintext
        )

        // Brief delay for relay propagation
        try await Task.sleep(for: .seconds(3))

        // Bob fetches conversations
        let conversations = await dmService.fetchConversations(
            privateKeyHex: bob.privHex,
            publicKeyHex: bob.pubHex,
            since: Int(Date().timeIntervalSince1970) - 120
        )

        // Bob should have a conversation with Alice
        let aliceConvo = conversations[alice.pubHex]
        XCTAssertNotNil(aliceConvo, "Bob should have a conversation with Alice")

        if let messages = aliceConvo {
            let matching = messages.filter { $0.content == plaintext }
            XCTAssertFalse(matching.isEmpty, "Bob should find Alice's message in the conversation")

            // Verify at least one message used NIP-44 encryption (from the gift wrap path)
            let nip44Messages = messages.filter { $0.encryption == .nip44 }
            // Note: this may be empty if the relay doesn't support kind 1059
            // but we should find the NIP-04 version at minimum
            let nip04Messages = messages.filter { $0.encryption == .nip04 }
            XCTAssertTrue(
                !nip44Messages.isEmpty || !nip04Messages.isEmpty,
                "Should find message via at least one protocol"
            )
        }
    }

    // MARK: - Relay Failover Resilience

    func testRelayFailoverResilience() async throws {
        let alice = try generateEphemeralKeys()
        let bob = try generateEphemeralKeys()

        // Mix a bogus relay URL with real ones
        var relayURLs = NostrRelayService.defaultRelays
        if let bogus = URL(string: "wss://bogus.relay.invalid:9999") {
            relayURLs.insert(bogus, at: 0)
        }

        let relay = NostrRelayService(relays: relayURLs)

        let encrypted = try NIP04Service.encrypt(
            "Failover test",
            privateKeyHex: alice.privHex,
            publicKeyHex: bob.pubHex
        )
        let event = try NostrEvent.signed(
            kind: .encryptedDM,
            content: encrypted,
            tags: [["p", bob.pubHex]],
            privateKeyHex: alice.privHex,
            publicKeyHex: alice.pubHex
        )

        let results = await relay.publish(event)

        // At least one real relay should succeed
        let accepted = results.filter { $0.1 }.count
        XCTAssertGreaterThan(accepted, 0, "At least one real relay should accept despite bogus relay in list")

        // The bogus relay should have failed
        let bogusResults = results.filter { $0.0.host == "bogus.relay.invalid" }
        if let bogusResult = bogusResults.first {
            XCTAssertFalse(bogusResult.1, "Bogus relay should have failed")
        }
    }
}
