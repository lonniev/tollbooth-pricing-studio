import XCTest
@testable import DPYCAuthKit

final class NIP46Tests: XCTestCase {

    private func keypair() throws -> (priv: String, pub: String) {
        let (nsec, npub) = try NostrKeyService.generateKeyPair()
        return (try NostrKeyService.privateKeyHexFromNsec(nsec),
                try NostrKeyService.publicKeyHexFromNpub(npub))
    }

    private let clientKey = String(repeating: "ab", count: 32)

    // MARK: - URI

    func testParsesAStackerNewsStyleToken() throws {
        let uri = try NostrConnectURI.parse(
            "nostrconnect://\(clientKey)?relay=wss%3A%2F%2Frelay.nsec.app&relay=wss://nos.lol"
            + "&secret=s3cr3t&name=Stacker%20News&url=https%3A%2F%2Fstacker.news&perms=sign_event%3A22242,nip44_encrypt"
        )
        XCTAssertEqual(uri.clientPubkey, clientKey)
        XCTAssertEqual(uri.relays.map(\.absoluteString), ["wss://relay.nsec.app", "wss://nos.lol"])
        XCTAssertEqual(uri.secret, "s3cr3t")
        XCTAssertEqual(uri.name, "Stacker News")
        XCTAssertEqual(uri.url, "https://stacker.news")
        XCTAssertEqual(uri.perms, ["sign_event:22242", "nip44_encrypt"])
    }

    func testRejectsBadTokens() {
        XCTAssertThrowsError(try NostrConnectURI.parse("bunker://\(clientKey)?relay=wss://a.b&secret=x")) {
            XCTAssertEqual($0 as? NostrConnectURI.ParseError, .notNostrConnect)
        }
        XCTAssertThrowsError(try NostrConnectURI.parse("nostrconnect://xyz?relay=wss://a.b&secret=x")) {
            XCTAssertEqual($0 as? NostrConnectURI.ParseError, .badClientKey)
        }
        XCTAssertThrowsError(try NostrConnectURI.parse("nostrconnect://\(clientKey)?relay=https://a.b&secret=x")) {
            XCTAssertEqual($0 as? NostrConnectURI.ParseError, .noRelay, "only wss:// relays count")
        }
        XCTAssertThrowsError(try NostrConnectURI.parse("nostrconnect://\(clientKey)?relay=wss://a.b")) {
            XCTAssertEqual($0 as? NostrConnectURI.ParseError, .noSecret)
        }
    }

    func testCapsRelaysAndDropsDuplicates() throws {
        let relays = ["a", "a", "b", "c", "d"].map { "relay=wss://\($0).example" }.joined(separator: "&")
        let uri = try NostrConnectURI.parse("nostrconnect://\(clientKey)?\(relays)&secret=x")
        XCTAssertEqual(uri.relays.count, NostrConnectURI.maxRelays)
        XCTAssertEqual(Set(uri.relays).count, uri.relays.count)
    }

    // MARK: - Bunker link

    func testBunkerLinkEncodesRelayAndSecret() throws {
        let link = BunkerURI.make(signerPubkey: clientKey, relays: [URL(string: "wss://relay.primal.net")!], secret: "a1b2")
        XCTAssertEqual(link, "bunker://\(clientKey)?relay=wss%3A%2F%2Frelay.primal.net&secret=a1b2")
        let comps = try XCTUnwrap(URLComponents(string: link))
        XCTAssertEqual(comps.host, clientKey)
        XCTAssertEqual(comps.queryItems?.first { $0.name == "relay" }?.value, "wss://relay.primal.net")
    }

    func testConnectNeedsTheSignerAndTheExactSecret() {
        let ok = NIP46Request(id: "1", method: "connect", params: [clientKey.uppercased(), "s3cr3t", "sign_event:22242"])
        XCTAssertTrue(NIP46.isConnect(ok, to: clientKey, secret: "s3cr3t"))
        XCTAssertFalse(NIP46.isConnect(ok, to: clientKey, secret: "s3cr3T"))
        XCTAssertFalse(NIP46.isConnect(ok, to: clientKey, secret: "s3cr3"))
        XCTAssertFalse(NIP46.isConnect(ok, to: String(repeating: "cd", count: 32), secret: "s3cr3t"))
        XCTAssertFalse(NIP46.isConnect(NIP46Request(id: "1", method: "connect", params: [clientKey]),
                                       to: clientKey, secret: "s3cr3t"), "a connect without the secret")
        XCTAssertFalse(NIP46.isConnect(NIP46Request(id: "1", method: "ping", params: [clientKey, "s3cr3t"]),
                                       to: clientKey, secret: "s3cr3t"))
    }

    // MARK: - Request / response round trip

    private func roundTrip(_ cipher: NIP46.Cipher) throws {
        let client = try keypair(), signer = try keypair()
        let request = NIP46Request(id: "r1", method: "get_public_key", params: [])
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let content = try NIP46.encrypt(json, cipher: cipher, privateKeyHex: client.priv, peerPublicKeyHex: signer.pub)
        let event = try NostrEvent.signed(
            kind: .nostrConnect, content: content, tags: [["p", signer.pub]],
            privateKeyHex: client.priv, publicKeyHex: client.pub
        )

        let (decoded, seen) = try NIP46.decryptRequest(event, signerPrivateKeyHex: signer.priv)
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(seen, cipher)

        let reply = try NIP46.responseEvent(
            NIP46Response(id: "r1", result: signer.pub), to: client.pub, cipher: seen,
            signerPrivateKeyHex: signer.priv, signerPublicKeyHex: signer.pub
        )
        XCTAssertEqual(reply.kind, 24133)
        XCTAssertEqual(reply.tags, [["p", client.pub]])
        XCTAssertTrue(verifyEventSignature(reply))
        let plain = try NIP46.decrypt(reply.content, cipher: cipher, privateKeyHex: client.priv, peerPublicKeyHex: signer.pub)
        let response = try JSONDecoder().decode(NIP46Response.self, from: Data(plain.utf8))
        XCTAssertEqual(response, NIP46Response(id: "r1", result: signer.pub))
    }

    func testRoundTripNIP44() throws { try roundTrip(.nip44) }
    func testRoundTripNIP04() throws { try roundTrip(.nip04) }

    func testRejectsATamperedRequest() throws {
        let client = try keypair(), signer = try keypair()
        let content = try NIP46.encrypt(#"{"id":"1","method":"ping","params":[]}"#, cipher: .nip44,
                                        privateKeyHex: client.priv, peerPublicKeyHex: signer.pub)
        let good = try NostrEvent.signed(kind: .nostrConnect, content: content, tags: [["p", signer.pub]],
                                         privateKeyHex: client.priv, publicKeyHex: client.pub)
        let forged = NostrEvent(id: good.id, pubkey: good.pubkey, created_at: good.created_at + 1,
                                kind: good.kind, tags: good.tags, content: good.content, sig: good.sig)
        XCTAssertThrowsError(try NIP46.decryptRequest(forged, signerPrivateKeyHex: signer.priv))
    }

    // MARK: - sign_event

    func testSignsAnyKindAsTheSigner() throws {
        let signer = try keypair()
        let unsigned = try NIP46.unsignedEvent(
            from: #"{"kind":22242,"content":"","tags":[["challenge","abc"]],"created_at":1700000000}"#
        )
        let json = try NIP46.sign(unsigned, privateKeyHex: signer.priv, publicKeyHex: signer.pub)
        let event = try JSONDecoder().decode(NostrEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.kind, 22242)
        XCTAssertEqual(event.pubkey, signer.pub)
        XCTAssertEqual(event.created_at, 1700000000)
        XCTAssertEqual(event.tags, [["challenge", "abc"]])
        XCTAssertTrue(verifyEventSignature(event))
    }
}
