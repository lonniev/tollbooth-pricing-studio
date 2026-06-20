import XCTest
@testable import PricingStudio

final class NostrCryptoTests: XCTestCase {

    // MARK: - Key Generation

    func testKeyPairGeneration() throws {
        let (nsec, npub) = try NostrKeyService.generateKeyPair()

        XCTAssertTrue(nsec.hasPrefix("nsec1"), "nsec should start with nsec1")
        XCTAssertTrue(npub.hasPrefix("npub1"), "npub should start with npub1")
        XCTAssertTrue(nsec.count > 10, "nsec should have meaningful length")
        XCTAssertTrue(npub.count > 10, "npub should have meaningful length")

        // Round-trip through hex
        let privHex = try NostrKeyService.privateKeyHexFromNsec(nsec)
        XCTAssertEqual(privHex.count, 64, "Private key hex should be 64 characters")

        let pubHex = try NostrKeyService.publicKeyHexFromNpub(npub)
        XCTAssertEqual(pubHex.count, 64, "Public key hex should be 64 characters")

        // Derive npub from nsec and verify match
        let derivedNpub = try NostrKeyService.npubFromNsec(nsec)
        XCTAssertEqual(derivedNpub, npub, "Derived npub should match original")

        // Hex round-trip for npub
        let npubFromHex = try NostrKeyService.npubFromHex(pubHex)
        XCTAssertEqual(npubFromHex, npub, "npub hex round-trip should be stable")
    }

    func testKeyPairUniqueness() throws {
        let (nsec1, npub1) = try NostrKeyService.generateKeyPair()
        let (nsec2, npub2) = try NostrKeyService.generateKeyPair()

        XCTAssertNotEqual(nsec1, nsec2, "Two generated keypairs should have distinct nsecs")
        XCTAssertNotEqual(npub1, npub2, "Two generated keypairs should have distinct npubs")
    }

    func testIsValidNsec() throws {
        let (nsec, _) = try NostrKeyService.generateKeyPair()
        XCTAssertTrue(NostrKeyService.isValidNsec(nsec))
        XCTAssertFalse(NostrKeyService.isValidNsec("not-an-nsec"))
        XCTAssertFalse(NostrKeyService.isValidNsec("npub1abc"))
        XCTAssertFalse(NostrKeyService.isValidNsec(""))
    }

    // MARK: - NIP-04 Encrypt / Decrypt

    func testNIP04EncryptDecryptRoundTrip() throws {
        let alice = try NostrKeyService.generateKeyPair()
        let bob = try NostrKeyService.generateKeyPair()

        let alicePriv = try NostrKeyService.privateKeyHexFromNsec(alice.nsec)
        let alicePub = try NostrKeyService.publicKeyHexFromNpub(alice.npub)
        let bobPriv = try NostrKeyService.privateKeyHexFromNsec(bob.nsec)
        let bobPub = try NostrKeyService.publicKeyHexFromNpub(bob.npub)

        let plaintext = "Hello Bob, this is a secret message from Alice!"

        // Alice encrypts with her privkey + Bob's pubkey
        let ciphertext = try NIP04Service.encrypt(plaintext, privateKeyHex: alicePriv, publicKeyHex: bobPub)

        XCTAssertTrue(ciphertext.contains("?iv="), "NIP-04 ciphertext should contain ?iv= separator")
        XCTAssertNotEqual(ciphertext, plaintext, "Ciphertext should differ from plaintext")

        // Bob decrypts with his privkey + Alice's pubkey
        let decrypted = try NIP04Service.decrypt(ciphertext, privateKeyHex: bobPriv, publicKeyHex: alicePub)

        XCTAssertEqual(decrypted, plaintext, "Bob should decrypt Alice's message correctly")
    }

    func testNIP04DecryptSymmetry() throws {
        let alice = try NostrKeyService.generateKeyPair()
        let bob = try NostrKeyService.generateKeyPair()

        let alicePriv = try NostrKeyService.privateKeyHexFromNsec(alice.nsec)
        let bobPriv = try NostrKeyService.privateKeyHexFromNsec(bob.nsec)
        let alicePub = try NostrKeyService.publicKeyHexFromNpub(alice.npub)
        let bobPub = try NostrKeyService.publicKeyHexFromNpub(bob.npub)

        // Both parties should derive the same shared secret
        let secretAB = try NIP04Service.sharedSecret(privateKeyHex: alicePriv, publicKeyHex: bobPub)
        let secretBA = try NIP04Service.sharedSecret(privateKeyHex: bobPriv, publicKeyHex: alicePub)

        XCTAssertEqual(secretAB, secretBA, "ECDH shared secret should be symmetric")
    }

    func testNIP04EmptyAndSpecialCharacters() throws {
        let alice = try NostrKeyService.generateKeyPair()
        let bob = try NostrKeyService.generateKeyPair()

        let alicePriv = try NostrKeyService.privateKeyHexFromNsec(alice.nsec)
        let bobPriv = try NostrKeyService.privateKeyHexFromNsec(bob.nsec)
        let alicePub = try NostrKeyService.publicKeyHexFromNpub(alice.npub)
        let bobPub = try NostrKeyService.publicKeyHexFromNpub(bob.npub)

        let messages = [
            "a",                                       // minimal
            "Unicode: \u{1F512}\u{1F4AC}\u{2705}",   // emoji
            String(repeating: "x", count: 1000),       // longer message
            "Special: <>&\"'\n\t\r\\",                 // special chars
        ]

        for msg in messages {
            let ct = try NIP04Service.encrypt(msg, privateKeyHex: alicePriv, publicKeyHex: bobPub)
            let pt = try NIP04Service.decrypt(ct, privateKeyHex: bobPriv, publicKeyHex: alicePub)
            XCTAssertEqual(pt, msg, "Round-trip should preserve message: \(msg.prefix(20))...")
        }
    }

    // MARK: - NIP-44 Encrypt / Decrypt

    func testNIP44EncryptDecryptRoundTrip() throws {
        let alice = try NostrKeyService.generateKeyPair()
        let bob = try NostrKeyService.generateKeyPair()

        let alicePriv = try NostrKeyService.privateKeyHexFromNsec(alice.nsec)
        let bobPriv = try NostrKeyService.privateKeyHexFromNsec(bob.nsec)
        let alicePub = try NostrKeyService.publicKeyHexFromNpub(alice.npub)
        let bobPub = try NostrKeyService.publicKeyHexFromNpub(bob.npub)

        let plaintext = "Hello Bob, this is a NIP-44 encrypted message!"

        // Alice encrypts
        let payload = try NIP44Service.encrypt(plaintext, privateKeyHex: alicePriv, publicKeyHex: bobPub)
        XCTAssertFalse(payload.isEmpty, "NIP-44 payload should not be empty")

        // Bob decrypts
        let decrypted = try NIP44Service.decrypt(payload, privateKeyHex: bobPriv, publicKeyHex: alicePub)
        XCTAssertEqual(decrypted, plaintext, "NIP-44 round-trip should preserve plaintext")
    }

    func testNIP44ConversationKeySymmetry() throws {
        let alice = try NostrKeyService.generateKeyPair()
        let bob = try NostrKeyService.generateKeyPair()

        let alicePriv = try NostrKeyService.privateKeyHexFromNsec(alice.nsec)
        let bobPriv = try NostrKeyService.privateKeyHexFromNsec(bob.nsec)
        let alicePub = try NostrKeyService.publicKeyHexFromNpub(alice.npub)
        let bobPub = try NostrKeyService.publicKeyHexFromNpub(bob.npub)

        let convKeyAB = try NIP44Service.conversationKey(privateKeyHex: alicePriv, publicKeyHex: bobPub)
        let convKeyBA = try NIP44Service.conversationKey(privateKeyHex: bobPriv, publicKeyHex: alicePub)

        // Compare key data
        let dataAB = convKeyAB.withUnsafeBytes { Data($0) }
        let dataBA = convKeyBA.withUnsafeBytes { Data($0) }
        XCTAssertEqual(dataAB, dataBA, "NIP-44 conversation key should be symmetric")
    }

    func testNIP44Padding() throws {
        // Verify padding round-trip for various sizes
        let sizes = [1, 15, 16, 31, 32, 33, 100, 255, 256, 1000]

        for size in sizes {
            let data = Data(repeating: 0x41, count: size)
            let padded = try NIP44Service.pad(data)
            let unpadded = try NIP44Service.unpad(padded)
            XCTAssertEqual(unpadded, data, "Padding round-trip should preserve data of size \(size)")
        }
    }

    // MARK: - Event Signing

    func testNostrEventSigning() throws {
        let (nsec, npub) = try NostrKeyService.generateKeyPair()
        let privHex = try NostrKeyService.privateKeyHexFromNsec(nsec)
        let pubHex = try NostrKeyService.publicKeyHexFromNpub(npub)

        let content = "Test event content"
        let tags: [[String]] = [["p", "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"]]

        let event = try NostrEvent.signed(
            kind: .encryptedDM,
            content: content,
            tags: tags,
            privateKeyHex: privHex,
            publicKeyHex: pubHex
        )

        XCTAssertEqual(event.pubkey, pubHex, "Event pubkey should match signer")
        XCTAssertEqual(event.kind, NostrEventKind.encryptedDM.rawValue)
        XCTAssertEqual(event.content, content)
        XCTAssertEqual(event.tags, tags)
        XCTAssertFalse(event.sig.isEmpty, "Signed event should have non-empty signature")
        XCTAssertEqual(event.id.count, 64, "Event ID should be 64-char hex")
        XCTAssertEqual(event.sig.count, 128, "Schnorr signature should be 128-char hex")

        // Verify id matches content hash
        let recomputedId = try computeEventId(
            pubkey: pubHex,
            createdAt: event.created_at,
            kind: event.kind,
            tags: event.tags,
            content: event.content
        )
        XCTAssertEqual(event.id, recomputedId, "Event ID should match recomputed hash")
    }

    func testNostrEventRumor() throws {
        let (_, npub) = try NostrKeyService.generateKeyPair()
        let pubHex = try NostrKeyService.publicKeyHexFromNpub(npub)

        let rumor = try NostrEvent.rumor(
            kind: .privateDM,
            content: "Unsigned rumor",
            tags: [["p", "recipientpubkeyhex"]],
            publicKeyHex: pubHex
        )

        XCTAssertEqual(rumor.sig, "", "Rumor should have empty signature")
        XCTAssertEqual(rumor.pubkey, pubHex)
        XCTAssertEqual(rumor.kind, NostrEventKind.privateDM.rawValue)
        XCTAssertFalse(rumor.id.isEmpty, "Rumor should still have a computed event ID")
    }

    func testNostrEventSerialization() throws {
        let (nsec, npub) = try NostrKeyService.generateKeyPair()
        let privHex = try NostrKeyService.privateKeyHexFromNsec(nsec)
        let pubHex = try NostrKeyService.publicKeyHexFromNpub(npub)

        let event = try NostrEvent.signed(
            kind: .encryptedDM,
            content: "Serialize me",
            tags: [],
            privateKeyHex: privHex,
            publicKeyHex: pubHex
        )

        let relayMessage = try event.toRelayMessage()
        XCTAssertTrue(relayMessage.hasPrefix("[\"EVENT\","), "Relay message should start with EVENT wrapper")
        XCTAssertTrue(relayMessage.contains(event.id), "Relay message should contain event ID")
    }

    // MARK: - kind-0 Profile Metadata

    func testProfileNormalizedTrimsAndDropsEmpty() {
        let m = NostrProfileMetadata(
            name: "  Sat  ", display_name: "", about: "   ",
            picture: "https://api.iconify.design/fluent-emoji-flat/fox.svg"
        ).normalized()
        XCTAssertEqual(m.name, "Sat")
        XCTAssertNil(m.display_name, "empty string should normalize to nil")
        XCTAssertNil(m.about, "whitespace-only should normalize to nil")
        XCTAssertEqual(m.picture, "https://api.iconify.design/fluent-emoji-flat/fox.svg")
    }

    func testProfileEncodeOmitsNilFields() throws {
        let m = NostrProfileMetadata(name: "Sat", picture: "https://x/y.svg").normalized()
        let json = String(data: try JSONEncoder().encode(m), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"name\""))
        XCTAssertTrue(json.contains("\"picture\""))
        XCTAssertFalse(json.contains("about"), "nil fields must be omitted")
        XCTAssertFalse(json.contains("lud16"))
    }

    func testProfileDecodeFromKind0Content() throws {
        let content = #"{"name":"Sat","picture":"https://x/y.svg","about":"hi","lud16":"s@w.com"}"#
        let m = try JSONDecoder().decode(NostrProfileMetadata.self, from: Data(content.utf8))
        XCTAssertEqual(m.name, "Sat")
        XCTAssertEqual(m.picture, "https://x/y.svg")
        XCTAssertEqual(m.about, "hi")
        XCTAssertEqual(m.lud16, "s@w.com")
        XCTAssertNil(m.website)
    }

    func testProfileSignedKind0IsValidEvent() throws {
        let (nsec, npub) = try NostrKeyService.generateKeyPair()
        let priv = try NostrKeyService.privateKeyHexFromNsec(nsec)
        let pub = try NostrKeyService.publicKeyHexFromNpub(npub)
        let content = #"{"name":"Sat"}"#
        let event = try NostrEvent.signed(
            kind: .metadata, content: content, tags: [],
            privateKeyHex: priv, publicKeyHex: pub
        )
        XCTAssertEqual(event.kind, 0)
        XCTAssertEqual(event.pubkey, pub)
        XCTAssertEqual(event.sig.count, 128, "Schnorr sig is 64 bytes / 128 hex chars")
        // Event id must be the canonical hash of the serialized event.
        let recomputed = try computeEventId(
            pubkey: pub, createdAt: event.created_at, kind: 0, tags: [], content: content
        )
        XCTAssertEqual(event.id, recomputed)
    }
}
