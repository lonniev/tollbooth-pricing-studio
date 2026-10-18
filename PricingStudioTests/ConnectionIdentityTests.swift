import CryptoKit
import DPYCAuthKit
import XCTest
@testable import PricingStudio

/// Identity rides the connection: a request either names no one
/// (`Bearer anonymous`) or is signed by the npub whose nsec Studio holds
/// (NIP-98), binding the method, the URL and the body.
final class ConnectionIdentityTests: XCTestCase {

    private let endpoint = URL(string: "https://example-mcp.fastmcp.app/mcp")!
    private var keys: (nsec: String, npub: String)!

    override func setUpWithError() throws {
        keys = try NostrKeyService.generateKeyPair()
        try KeychainService.saveNsec(keys.nsec, forNpub: keys.npub)
    }

    override func tearDown() {
        KeychainService.deleteNsec(forNpub: keys.npub)
        super.tearDown()
    }

    private func post(_ body: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        return request
    }

    private func event(in header: String?) throws -> NostrEvent {
        let header = try XCTUnwrap(header)
        XCTAssertTrue(header.hasPrefix("Nostr "))
        let data = try XCTUnwrap(Data(base64Encoded: String(header.dropFirst("Nostr ".count))))
        return try JSONDecoder().decode(NostrEvent.self, from: data)
    }

    private func tag(_ name: String, _ event: NostrEvent) -> String? {
        event.tags.first { $0.first == name }?.last
    }

    func testAnAnonymousCallerCarriesTheAnonymousBearer() async {
        var request = post("{}")
        request.setValue("Bearer stale", forHTTPHeaderField: "Authorization")
        let authorize = await MCPService.authorization(as: .anonymous, endpoint: endpoint)
        XCTAssertEqual(authorize(request).value(forHTTPHeaderField: "Authorization"), "Bearer anonymous")
    }

    func testAKeyHolderSignsTheRequest() async throws {
        let body = #"{"jsonrpc":"2.0","method":"tools/call"}"#
        let authorize = await MCPService.authorization(as: .npub(keys.npub), endpoint: endpoint)
        let event = try event(in: authorize(post(body)).value(forHTTPHeaderField: "Authorization"))

        XCTAssertTrue(verifyEventSignature(event))
        XCTAssertEqual(event.kind, 27235)
        XCTAssertEqual(event.pubkey, try NostrKeyService.publicKeyHexFromNpub(keys.npub))
        XCTAssertEqual(tag("u", event), endpoint.absoluteString)
        XCTAssertEqual(tag("method", event), "POST")
        let digest = SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(tag("payload", event), digest)
    }

    func testTwoIdenticalRequestsAreDistinctEvents() async throws {
        let authorize = await MCPService.authorization(as: .npub(keys.npub), endpoint: endpoint)
        let first = try event(in: authorize(post("{}")).value(forHTTPHeaderField: "Authorization"))
        let second = try event(in: authorize(post("{}")).value(forHTTPHeaderField: "Authorization"))
        XCTAssertNotEqual(first.id, second.id)
    }

    func testAGetSignsTheEmptyBody() async throws {
        let authorize = await MCPService.authorization(as: .npub(keys.npub), endpoint: endpoint)
        let event = try event(in: authorize(URLRequest(url: endpoint)).value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(tag("method", event), "GET")
        XCTAssertEqual(tag("payload", event), SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined())
    }
}
