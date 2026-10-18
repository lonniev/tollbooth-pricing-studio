import XCTest
@testable import PricingStudio

/// Pins the decode contract for the Authority `list_operator_requests`
/// response — the wire shape the Pending Requests queue depends on.
final class OperatorRequestDecodeTests: XCTestCase {

    /// Mirrors `MCPService.OperatorRequestList` (which is private) so the
    /// test exercises the same snake_case → struct mapping the VM relies on.
    private struct Response: Decodable {
        let requests: [MCPService.OperatorRequest]
    }

    func testDecodesAdoptionsAndUpdates() throws {
        let json = """
        {
          "success": true,
          "count": 2,
          "requests": [
            {
              "operator_npub": "npub1operatoraaa",
              "kind": "adoption",
              "service_url": "https://cypher-mcp.fastmcp.app/mcp",
              "display_name": "Cypher",
              "note": "please adopt me",
              "requested_at": "2026-06-17 11:29:04.079717+00",
              "expires_at": "2026-06-24 11:29:04.079717+00"
            },
            {
              "operator_npub": "npub1operatoraaa",
              "kind": "update",
              "service_url": "https://cypher.example/mcp",
              "display_name": "",
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
        XCTAssertEqual(rows[0].kind, MCPService.OperatorRequest.adoption)
        XCTAssertFalse(rows[0].isUpdate)
        XCTAssertEqual(rows[0].serviceURL, "https://cypher-mcp.fastmcp.app/mcp")
        XCTAssertEqual(rows[0].displayName, "Cypher")
        XCTAssertEqual(rows[0].note, "please adopt me")
        XCTAssertEqual(rows[0].requestedAt, "2026-06-17 11:29:04.079717+00")
        XCTAssertEqual(rows[0].expiresAt, "2026-06-24 11:29:04.079717+00")
        XCTAssertTrue(rows[1].isUpdate)
        // One operator may have an adoption and an update pending: ids differ.
        XCTAssertNotEqual(rows[0].id, rows[1].id)
    }

    func testDecodesEmptyQueue() throws {
        let json = #"{ "success": true, "count": 0, "requests": [] }"#
        let rows = try JSONDecoder().decode(Response.self, from: Data(json.utf8)).requests
        XCTAssertTrue(rows.isEmpty)
    }

    /// A sparse row (missing optional fields) must still decode with empty
    /// defaults rather than throwing — the custom initializer's job. A row
    /// without a kind is an adoption.
    func testDecodesSparseRowWithDefaults() throws {
        let json = #"{ "requests": [ { "operator_npub": "npub1only" } ] }"#
        let rows = try JSONDecoder().decode(Response.self, from: Data(json.utf8)).requests

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].operatorNpub, "npub1only")
        XCTAssertEqual(rows[0].kind, MCPService.OperatorRequest.adoption)
        XCTAssertEqual(rows[0].serviceURL, "")
        XCTAssertEqual(rows[0].displayName, "")
        XCTAssertEqual(rows[0].note, "")
        XCTAssertEqual(rows[0].requestedAt, "")
        XCTAssertEqual(rows[0].expiresAt, "")
    }
}
