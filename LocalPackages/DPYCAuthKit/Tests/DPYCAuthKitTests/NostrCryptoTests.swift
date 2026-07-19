import DPYCAuthKit
import XCTest

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

    // MARK: - Event ID Determinism

    /// Pinned fixture: the canonical NIP-01 serialization must hash to the
    /// same id on every platform this package builds for. Guards against a
    /// JSONSerialization behavior change silently breaking event ids.
    func testEventIdMatchesPinnedFixture() throws {
        let id = try computeEventId(
            pubkey: String(repeating: "a", count: 64),
            createdAt: 1_700_000_000,
            kind: 1,
            tags: [],
            content: "hello nostr"
        )
        XCTAssertEqual(id, "4134b676f7cab3bcd24bd5e1acfc2d19ebbde7d3e01ab26cb8fa8b03ede08a39")
    }

    // MARK: - Schnorr Verification

    func testVerifyEventSignatureRoundTrip() throws {
        let (nsec, npub) = try NostrKeyService.generateKeyPair()
        let priv = try NostrKeyService.privateKeyHexFromNsec(nsec)
        let pub = try NostrKeyService.publicKeyHexFromNpub(npub)

        let event = try NostrEvent.signed(
            kind: .httpAuth,
            content: "",
            tags: [["u", "npub_proof_request"], ["challenge", "bold-hawk-42"]],
            privateKeyHex: priv,
            publicKeyHex: pub
        )

        XCTAssertTrue(verifyEventSignature(event), "A freshly signed event must verify")
    }

    func testVerifyRejectsTamperedTags() throws {
        let (nsec, npub) = try NostrKeyService.generateKeyPair()
        let priv = try NostrKeyService.privateKeyHexFromNsec(nsec)
        let pub = try NostrKeyService.publicKeyHexFromNpub(npub)

        let event = try NostrEvent.signed(
            kind: .httpAuth,
            content: "",
            tags: [["challenge", "bold-hawk-42"]],
            privateKeyHex: priv,
            publicKeyHex: pub
        )
        // Swap a bound tag after signing — id no longer recomputes, sig is stale.
        let tampered = NostrEvent(
            id: event.id, pubkey: event.pubkey, created_at: event.created_at,
            kind: event.kind, tags: [["challenge", "calm-wolf-99"]],
            content: event.content, sig: event.sig
        )

        XCTAssertFalse(verifyEventSignature(tampered), "Tampered tags must fail verification")
    }

    func testVerifyRejectsWrongSigner() throws {
        let (nsec, npub) = try NostrKeyService.generateKeyPair()
        let priv = try NostrKeyService.privateKeyHexFromNsec(nsec)
        let pub = try NostrKeyService.publicKeyHexFromNpub(npub)
        let event = try NostrEvent.signed(
            kind: .httpAuth, content: "", tags: [["u", "npub_proof_request"]],
            privateKeyHex: priv, publicKeyHex: pub
        )

        // Re-label the event as authored by a different pubkey — sig won't match.
        let (_, otherNpub) = try NostrKeyService.generateKeyPair()
        let otherPub = try NostrKeyService.publicKeyHexFromNpub(otherNpub)
        let impersonated = NostrEvent(
            id: event.id, pubkey: otherPub, created_at: event.created_at,
            kind: event.kind, tags: event.tags, content: event.content, sig: event.sig
        )

        XCTAssertFalse(verifyEventSignature(impersonated), "Wrong signer must fail verification")
    }

    func testVerifyRejectsMalformed() {
        let junk = NostrEvent(
            id: "zz", pubkey: "not-hex", created_at: 1, kind: 27235,
            tags: [], content: "", sig: "short"
        )
        XCTAssertFalse(verifyEventSignature(junk), "Malformed fields must fail, not throw")
    }

    /// Cross-language guarantee: a provenance attestation generated by the
    /// Python SDK (`identity_proof.create_provenance_attestation`) must verify
    /// with this Swift implementation. Pinned fixture — regenerate only if the
    /// canonical NIP-01 serialization intentionally changes on either side.
    func testVerifyPythonGeneratedAttestationFixture() throws {
        let json = #"""
        {"id": "b4319e4165813c5697bbb45c5a84eac4ac8a08cc6f0e5a43039d2ea36ffede34", "pubkey": "c812f06c4a4e8ec1b81fc4394fd3845599a5c36baf986e96da9e7c924e8073c7", "created_at": 1784481570, "kind": 27235, "tags": [["u", "npub_proof_request"], ["sender", "cab7a8a0b79b507ac0f52c5bed3705e0a646d2ca379b1adb9d8dfd2681af7f54"], ["subject", "npub1w4jmdng7hfzy85j0y9eapgtt2qe6v02f88vv8r35zf6zv7339paq26huw2"], ["service", "x"], ["challenge", "bold-hawk-42"], ["nonce", "5be3886aacad70767ba3d9109d0d4cf3"]], "content": "", "sig": "f31d06a6400eb10d6e8305f04c80a62bf066be397f3ba62da76c6f5a6d5fe18e75dca65e73165f52779c7fc3028e49c664176172559c173685a96f7e8e8bca7b"}
        """#
        let event = try JSONDecoder().decode(NostrEvent.self, from: Data(json.utf8))
        XCTAssertTrue(verifyEventSignature(event), "Python-signed attestation must verify in Swift")

        // Flip one bound tag — id no longer recomputes → must fail.
        let tampered = NostrEvent(
            id: event.id, pubkey: event.pubkey, created_at: event.created_at,
            kind: event.kind,
            tags: [["u", "npub_proof_request"], ["challenge", "calm-wolf-99"]],
            content: event.content, sig: event.sig
        )
        XCTAssertFalse(verifyEventSignature(tampered), "Tampered Python fixture must fail")
    }
}
