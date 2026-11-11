import XCTest
@testable import PricingStudio

/// A connected app shows the name the user gave it, else its own.
final class NostrConnectSessionNameTests: XCTestCase {

    private let client = String(repeating: "45c25675", count: 8)

    private func session(appName: String? = nil, label: String? = nil) -> NostrConnectSession {
        NostrConnectSession(
            clientPubkey: client, signerNpub: "npub1x", signerPubkey: String(repeating: "ab", count: 32),
            relays: [URL(string: "wss://relay.primal.net")!], appName: appName, appURL: nil,
            pairedAt: Date(timeIntervalSince1970: 0), label: label
        )
    }

    func testTheUsersNameWins() {
        XCTAssertEqual(session().displayName, "App 45c25675")
        XCTAssertEqual(session(appName: "Primal").displayName, "Primal")
        XCTAssertEqual(session(appName: "Primal", label: "Stacker News").displayName, "Stacker News")
    }

    func testSessionsSavedBeforeNamesStillLoad() throws {
        var saved = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(session())) as? [String: Any]
        )
        saved["label"] = nil
        let data = try JSONSerialization.data(withJSONObject: saved)
        let loaded = try JSONDecoder().decode(NostrConnectSession.self, from: data)
        XCTAssertNil(loaded.label)
        XCTAssertEqual(loaded.displayName, "App 45c25675")
    }

    func testNamesAreTrimmedAndCapped() {
        XCTAssertNil(NostrConnectService.cleanLabel("   "))
        XCTAssertNil(NostrConnectService.cleanLabel(nil))
        XCTAssertEqual(NostrConnectService.cleanLabel("  Stacker News \n"), "Stacker News")
        XCTAssertEqual(NostrConnectService.cleanLabel(String(repeating: "x", count: 99))?.count, 40)
    }
}
