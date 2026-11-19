import XCTest
@testable import PricingStudio

/// The Edit Patron sheet keeps what was typed while the relays' profile arrives,
/// and says when a Save reached no relay.
final class ProfileFillTests: XCTestCase {
    private let relay = URL(string: "wss://relay.example")!

    func testARelayValueFillsAnUntouchedField() {
        XCTAssertEqual(ProfileFill.fill("", opened: "", relay: "https://site.example"), "https://site.example")
        XCTAssertEqual(ProfileFill.fill("", opened: "", relay: nil), "")
    }

    func testWhatWasTypedIsNeverOverwritten() {
        XCTAssertEqual(ProfileFill.fill("https://typed.example", opened: "", relay: "https://old.example"),
                       "https://typed.example")
    }

    func testAPictureKeptOnDeviceSurvivesARelayWithout() {
        XCTAssertEqual(ProfileFill.fill("https://a/p.png", opened: "https://a/p.png", relay: "", keepWhenRelayEmpty: true),
                       "https://a/p.png")
        XCTAssertEqual(ProfileFill.fill("https://a/p.png", opened: "https://a/p.png", relay: "https://b/q.png",
                                        keepWhenRelayEmpty: true), "https://b/q.png")
    }

    func testAPublishSaysWhenNoRelayAcceptedIt() {
        XCTAssertNil(ProfileFill.problem([(relay, false, "timeout"), (relay, true, "")]))
        XCTAssertNotNil(ProfileFill.problem([]))
        let problem = ProfileFill.problem([(relay, false, "blocked")])
        XCTAssertTrue(problem?.contains("relay.example: blocked") ?? false)
    }
}
