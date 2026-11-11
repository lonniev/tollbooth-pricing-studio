import DPYCAuthKit
import XCTest
@testable import PricingStudio

final class NostrProfileMetadataTests: XCTestCase {

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

    // MARK: - NIP-05 merge

    func testMergedSetsNip05AndKeepsEveryOtherField() {
        let current = NostrProfileMetadata(
            name: "thebrain-mcp", about: "graph", picture: "https://x/y.svg", lud16: "s@w.com"
        )
        let m = NostrProfileService.merged(
            current, nip05: "thebrain@tollbooth-dpyc.org", displayName: "TheBrain MCP"
        )
        XCTAssertEqual(m.nip05, "thebrain@tollbooth-dpyc.org")
        XCTAssertEqual(m.name, "thebrain-mcp", "an existing name is never overwritten")
        XCTAssertEqual(m.display_name, "TheBrain MCP", "an empty display_name is filled")
        XCTAssertEqual(m.about, "graph")
        XCTAssertEqual(m.picture, "https://x/y.svg")
        XCTAssertEqual(m.lud16, "s@w.com")
    }

    func testMergedWithNoProfileFillsTheName() {
        let m = NostrProfileService.merged(
            nil, nip05: "cypher@tollbooth-dpyc.org", displayName: "Cypher MCP"
        )
        XCTAssertEqual(m.name, "Cypher MCP")
        XCTAssertEqual(m.display_name, "Cypher MCP")
        XCTAssertEqual(m.nip05, "cypher@tollbooth-dpyc.org")
    }

    func testMergedWithClearedNip05DropsTheClaim() {
        let current = NostrProfileMetadata(name: "Sat", nip05: "sat@tollbooth-dpyc.org")
        let m = NostrProfileService.merged(current, nip05: nil, displayName: "Sat")
        XCTAssertNil(m.nip05)
        XCTAssertEqual(m.name, "Sat")
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
