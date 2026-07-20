import XCTest
@testable import PricingStudio

/// The Network Books Health panel must NOT conflate a tool-discovery gap
/// (the Authority's wheel simply doesn't expose `network_books_health`) with a
/// genuine datastore/backend health failure. A capability gap is calm and not
/// retryable; a real failure earns the orange alarm and a Retry button.
/// `AuthorityDetailView.classifyBooksHealthLoad` is the seam that keeps them
/// apart, so it's pinned here.
final class NetworkBooksHealthErrorClassificationTests: XCTestCase {

    /// Regression for #100: a missing tool must resolve to `.unavailable`
    /// (informational, no Retry) — before the fix it flowed through the
    /// generic error path and rendered as a backend health alarm.
    func testMissingToolClassifiesAsUnavailableNotHealthError() {
        let err = MCPError.capabilityUnavailable(
            capability: "network_books_health",
            detail: "This Authority’s wheel doesn’t offer network books health monitoring yet."
        )
        guard case .unavailable(let msg) = AuthorityDetailView.classifyBooksHealthLoad(err) else {
            return XCTFail("Tool-discovery gap must classify as .unavailable, not a health error")
        }
        XCTAssertFalse(msg.isEmpty)
    }

    /// A soft quota/backend error the wheel actually returned IS a health
    /// problem — it keeps the retryable `.error` treatment.
    func testStructuredSoftErrorClassifiesAsHealthError() {
        let err = MCPError.structuredError(
            code: "quota_exhausted",
            message: "Neon HTTP 402: compute quota exceeded",
            extras: [:]
        )
        XCTAssertEqual(
            AuthorityDetailView.classifyBooksHealthLoad(err),
            .error("Neon HTTP 402: compute quota exceeded")
        )
    }

    /// A structured error with an empty message falls back to its code.
    func testStructuredErrorFallsBackToCode() {
        let err = MCPError.structuredError(code: "authority_proof_invalid", message: "", extras: [:])
        XCTAssertEqual(
            AuthorityDetailView.classifyBooksHealthLoad(err),
            .error("authority_proof_invalid")
        )
    }

    /// A dropped connection is a genuine health failure, not a capability gap.
    func testConnectionFailureClassifiesAsHealthError() {
        guard case .error = AuthorityDetailView.classifyBooksHealthLoad(
            MCPError.connectionFailed("timeout")
        ) else {
            return XCTFail("A connection failure is a retryable health error")
        }
    }
}
