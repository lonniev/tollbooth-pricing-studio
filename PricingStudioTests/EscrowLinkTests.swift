import XCTest
@testable import PricingStudio

/// A site's escrow link names only where to ask; anything else is not opened.
final class EscrowLinkTests: XCTestCase {
    private let npub = "npub1efh22mm3x5f7xkgresq5sz5waw2vk0h4qw2vg2wfckrckmexxvqqacfd4v"

    private func link(_ query: String) -> EscrowLink? {
        EscrowLink(url: URL(string: "com.tollbooth.dpyc.pricingstudio://escrow?\(query)")!)
    }

    func testReadsAWellFormedLink() throws {
        let l = try XCTUnwrap(link("mcp=https%3A%2F%2Ftaskbooth-mcp.fastmcp.app%2Fmcp&task=e6c0cfb125950024&npub=\(npub)&tool=taskbooth"))
        XCTAssertEqual(l.mcp.absoluteString, "https://taskbooth-mcp.fastmcp.app/mcp")
        XCTAssertEqual(l.taskId, "e6c0cfb125950024")
        XCTAssertEqual(l.npub, npub)
    }

    func testRefusesPlainHttpALocalHostOrCredentials() {
        XCTAssertNil(link("mcp=http%3A%2F%2Ftb.example%2Fmcp&task=e6c0cfb125950024&npub=\(npub)"))
        XCTAssertNil(link("mcp=https%3A%2F%2Flocalhost%2Fmcp&task=e6c0cfb125950024&npub=\(npub)"))
        XCTAssertNil(link("mcp=https%3A%2F%2Fu%3Ap%40tb.example%2Fmcp&task=e6c0cfb125950024&npub=\(npub)"))
    }

    func testRefusesABadTaskOrNpubOrAnotherPath() {
        XCTAssertNil(link("mcp=https%3A%2F%2Ftb.example%2Fmcp&task=..%2Fx&npub=\(npub)"))
        XCTAssertNil(link("mcp=https%3A%2F%2Ftb.example%2Fmcp&task=e6c0cfb125950024&npub=npub1nope"))
        XCTAssertNil(EscrowLink(url: URL(string: "com.tollbooth.dpyc.pricingstudio://oauth?mcp=https%3A%2F%2Ftb.example%2Fmcp&task=e6c0cfb125950024&npub=\(npub)")!))
    }
}
