import XCTest
@testable import PricingStudio

/// Pins the decode contract for the Authority `list_adoption_requests`
/// response — the wire shape the Pending Adoptions queue depends on.
final class AdoptionRequestDecodeTests: XCTestCase {

    /// Mirrors `MCPService.AdoptionListResponse` (which is private) so the
    /// test exercises the same snake_case → struct mapping the VM relies on.
    private struct Response: Decodable {
        let requests: [MCPService.AdoptionRequest]
    }

    func testDecodesPopulatedQueue() throws {
        let json = """
        {
          "success": true,
          "count": 2,
          "requests": [
            {
              "operator_npub": "npub1operatoraaa",
              "service_url": "https://cypher-mcp.fastmcp.app/mcp",
              "note": "please adopt me",
              "requested_at": "2026-06-17 11:29:04.079717+00",
              "expires_at": "2026-06-24 11:29:04.079717+00"
            },
            {
              "operator_npub": "npub1operatorbbb",
              "service_url": "https://other.example/mcp",
              "note": "",
              "requested_at": "2026-06-16 08:00:00+00",
              "expires_at": "2026-06-23 08:00:00+00"
            }
          ]
        }
        """
        let rows = try JSONDecoder().decode(Response.self, from: Data(json.utf8)).requests

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].operatorNpub, "npub1operatoraaa")
        XCTAssertEqual(rows[0].serviceURL, "https://cypher-mcp.fastmcp.app/mcp")
        XCTAssertEqual(rows[0].note, "please adopt me")
        XCTAssertEqual(rows[0].requestedAt, "2026-06-17 11:29:04.079717+00")
        XCTAssertEqual(rows[0].expiresAt, "2026-06-24 11:29:04.079717+00")
        // id is the operator npub (Identifiable for ForEach).
        XCTAssertEqual(rows[0].id, "npub1operatoraaa")
    }

    func testDecodesEmptyQueue() throws {
        let json = #"{ "success": true, "count": 0, "requests": [] }"#
        let rows = try JSONDecoder().decode(Response.self, from: Data(json.utf8)).requests
        XCTAssertTrue(rows.isEmpty)
    }

    /// A sparse row (missing optional fields) must still decode with empty
    /// defaults rather than throwing — the custom initializer's job.
    func testDecodesSparseRowWithDefaults() throws {
        let json = #"{ "requests": [ { "operator_npub": "npub1only" } ] }"#
        let rows = try JSONDecoder().decode(Response.self, from: Data(json.utf8)).requests

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].operatorNpub, "npub1only")
        XCTAssertEqual(rows[0].serviceURL, "")
        XCTAssertEqual(rows[0].note, "")
        XCTAssertEqual(rows[0].requestedAt, "")
        XCTAssertEqual(rows[0].expiresAt, "")
    }
}
