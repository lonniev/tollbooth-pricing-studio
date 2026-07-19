import XCTest
@testable import PricingStudio

/// Pins the decode contract for the restricted Authority
/// `network_books_health` response — the wire shape the Network Books Health
/// panel depends on. Mirrors `AdoptionRequestDecodeTests` in intent.
final class NeonBooksHealthDecodeTests: XCTestCase {

    func testDecodesExhaustedProjectAndOverallStatus() throws {
        let json = """
        {
          "success": true,
          "overall_status": "exhausted",
          "own_books": { "status": "ok", "detail": "" },
          "operator_alerts": [
            {
              "operator_npub": "npub1operatoraaa",
              "detail": "Neon HTTP 402: compute quota exceeded",
              "seen_count": 2,
              "first_seen_at": "2026-07-19T14:00:00Z",
              "last_seen_at": "2026-07-19T14:30:00Z"
            }
          ],
          "operator_alert_count": 1,
          "neon_api": {
            "configured": true,
            "projects": [
              {
                "project_id": "ancient-water-19642944",
                "name": "ancient-water",
                "compute_seconds_used": 700000,
                "compute_hours_used": 194.4,
                "allowance_hours": 191.9,
                "used_pct": 101.3,
                "quota_reset_at": "2026-08-01T00:00:00Z",
                "status": "exhausted"
              }
            ]
          }
        }
        """
        let health = try JSONDecoder().decode(MCPService.NeonBooksHealth.self, from: Data(json.utf8))

        XCTAssertTrue(health.success)
        XCTAssertEqual(health.overallStatus, "exhausted")
        XCTAssertEqual(health.ownBooks.status, "ok")

        XCTAssertEqual(health.operatorAlertCount, 1)
        XCTAssertEqual(health.operatorAlerts.count, 1)
        XCTAssertEqual(health.operatorAlerts[0].operatorNpub, "npub1operatoraaa")
        XCTAssertEqual(health.operatorAlerts[0].seenCount, 2)
        XCTAssertEqual(health.operatorAlerts[0].lastSeenAt, "2026-07-19T14:30:00Z")

        XCTAssertTrue(health.neonApi.configured)
        XCTAssertEqual(health.neonApi.projects.count, 1)
        let project = try XCTUnwrap(health.neonApi.projects.first)
        XCTAssertEqual(project.projectId, "ancient-water-19642944")
        XCTAssertEqual(project.name, "ancient-water")
        XCTAssertEqual(project.allowanceHours, 191.9, accuracy: 0.001)
        XCTAssertEqual(project.usedPct, 101.3, accuracy: 0.001)
        XCTAssertEqual(project.status, "exhausted")
        XCTAssertEqual(project.quotaResetAt, "2026-08-01T00:00:00Z")
    }

    /// `configured == false` means monitoring isn't enabled — a calm state
    /// carrying a hint, not an error. It must decode with an empty project list.
    func testDecodesUnconfiguredNeonApi() throws {
        let json = """
        {
          "success": true,
          "overall_status": "ok",
          "own_books": { "status": "ok", "detail": "" },
          "operator_alerts": [],
          "operator_alert_count": 0,
          "neon_api": {
            "configured": false,
            "hint": "Set NEON_API_KEY to enable proactive monitoring."
          }
        }
        """
        let health = try JSONDecoder().decode(MCPService.NeonBooksHealth.self, from: Data(json.utf8))

        XCTAssertEqual(health.overallStatus, "ok")
        XCTAssertFalse(health.neonApi.configured)
        XCTAssertEqual(health.neonApi.hint, "Set NEON_API_KEY to enable proactive monitoring.")
        XCTAssertTrue(health.neonApi.projects.isEmpty)
        XCTAssertTrue(health.operatorAlerts.isEmpty)
    }

    /// The Authority's own books being 402-locked drives the loud red banner.
    func testDecodesOwnBooksQuotaExceeded() throws {
        let json = """
        {
          "success": true,
          "overall_status": "critical",
          "own_books": { "status": "quota_exceeded", "detail": "Neon HTTP 402" },
          "operator_alerts": [],
          "operator_alert_count": 0,
          "neon_api": { "configured": true, "projects": [] }
        }
        """
        let health = try JSONDecoder().decode(MCPService.NeonBooksHealth.self, from: Data(json.utf8))

        XCTAssertEqual(health.overallStatus, "critical")
        XCTAssertEqual(health.ownBooks.status, "quota_exceeded")
        XCTAssertEqual(health.ownBooks.detail, "Neon HTTP 402")
    }
}
