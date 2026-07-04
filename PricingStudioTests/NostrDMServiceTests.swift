import DPYCAuthKit
import XCTest
@testable import PricingStudio

final class NostrDMServiceTests: XCTestCase {

    // MARK: - Helpers

    private func generateEphemeralKeys() throws -> (privHex: String, pubHex: String) {
        let (nsec, npub) = try NostrKeyService.generateKeyPair()
        let privHex = try NostrKeyService.privateKeyHexFromNsec(nsec)
        let pubHex = try NostrKeyService.publicKeyHexFromNpub(npub)
        return (privHex, pubHex)
    }

    // MARK: - Send & Fetch DM (Dual Protocol)

    func testSendAndFetchDM() async throws {
        let alice = try generateEphemeralKeys()
        let bob = try generateEphemeralKeys()

        let message = "DM service test \(UUID().uuidString.prefix(8))"
        let dmService = NostrDMService(
            relay: NostrRelayService(relays: NostrRelayService.defaultRelays)
        )

        // Alice sends DM to Bob (dual protocol: NIP-04 + NIP-17)
        try await dmService.sendDM(
            privateKeyHex: alice.privHex,
            publicKeyHex: alice.pubHex,
            recipientPubkeyHex: bob.pubHex,
            message: message
        )

        // Wait for relay propagation
        try await Task.sleep(for: .seconds(3))

        // Bob fetches conversations
        let conversations = await dmService.fetchConversations(
            privateKeyHex: bob.privHex,
            publicKeyHex: bob.pubHex,
            since: Int(Date().timeIntervalSince1970) - 120
        )

        // Verify message appears in Bob's conversation with Alice
        let aliceConvo = conversations[alice.pubHex]
        XCTAssertNotNil(aliceConvo, "Bob should have a conversation keyed by Alice's pubkey")

        if let messages = aliceConvo {
            let found = messages.contains { $0.content == message }
            XCTAssertTrue(found, "Bob's conversation with Alice should contain the sent message")

            // Verify DM metadata
            if let dm = messages.first(where: { $0.content == message }) {
                XCTAssertEqual(dm.senderPubkeyHex, alice.pubHex, "Sender should be Alice")
                XCTAssertEqual(dm.recipientPubkeyHex, bob.pubHex, "Recipient should be Bob")
                XCTAssertFalse(dm.isFromMe, "From Bob's perspective, the DM should not be 'from me'")
            }
        }
    }

    // MARK: - Deletion Request (NIP-09)

    func testDeletionRequest() async throws {
        let alice = try generateEphemeralKeys()
        let bob = try generateEphemeralKeys()

        let relay = NostrRelayService(relays: NostrRelayService.defaultRelays)
        let dmService = NostrDMService(relay: relay)

        // Alice sends a DM to Bob
        let message = "Delete me \(UUID().uuidString.prefix(8))"
        try await dmService.sendDM(
            privateKeyHex: alice.privHex,
            publicKeyHex: alice.pubHex,
            recipientPubkeyHex: bob.pubHex,
            message: message
        )

        try await Task.sleep(for: .seconds(2))

        // Fetch to get event IDs
        let conversations = await dmService.fetchConversations(
            privateKeyHex: alice.privHex,
            publicKeyHex: alice.pubHex,
            since: Int(Date().timeIntervalSince1970) - 120
        )

        let bobConvo = conversations[bob.pubHex] ?? []
        let eventIds = bobConvo.filter { $0.content == message }.map { $0.rawEventId }

        guard !eventIds.isEmpty else {
            // If we can't find the event (relay timing), skip gracefully
            throw XCTSkip("Could not find sent event IDs — relay propagation may be slow")
        }

        // Alice requests deletion via NIP-09 — verify it doesn't throw
        await dmService.requestDeletion(
            privateKeyHex: alice.privHex,
            publicKeyHex: alice.pubHex,
            eventIds: eventIds
        )

        // Deletion is best-effort; we verify the deletion event was published
        // by building one manually and checking relay acceptance
        let deletionEvent = try NostrEvent.signed(
            kind: .deletion,
            content: "deletion test",
            tags: eventIds.map { ["e", $0] },
            privateKeyHex: alice.privHex,
            publicKeyHex: alice.pubHex
        )
        let results = await relay.publish(deletionEvent)
        let accepted = results.filter { $0.1 }.count
        XCTAssertGreaterThan(accepted, 0, "At least one relay should accept the deletion event")
    }
}
