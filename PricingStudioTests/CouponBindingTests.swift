import XCTest
@testable import PricingStudio

/// A coupon owns the tools it applies to (tollbooth-dpyc 0.98.0): the
/// wire field is `tool_ids`, `["*"]` is every paid tool, `[]` is none.
/// These pin the decode, the picker's round trip, and that the chain
/// editor no longer offers a `coupon` step.
final class CouponBindingTests: XCTestCase {

    private func decode(_ json: String) throws -> Coupon {
        try JSONDecoder().decode(Coupon.self, from: Data(json.utf8))
    }

    private static let base = """
    "id": "0c0365b1-b56b-46de-b568-be7a48fc31ea",
    "operator": "npub1operator",
    "name": "PIONEER100PERCENT",
    "discount_percent": 100,
    "valid_from": "2026-10-01T00:00:00Z",
    "valid_until": "2027-10-01T00:00:00Z",
    "times_redeemed": 3
    """

    func testDecodesWildcardBinding() throws {
        let c = try decode("{\(Self.base), \"tool_ids\": [\"*\"]}")
        XCTAssertTrue(c.appliesToEveryPaidTool)
        XCTAssertEqual(c.appliesToLabel, "Every paid tool")
    }

    func testDecodesChosenTools() throws {
        let c = try decode("{\(Self.base), \"tool_ids\": [\"aaa\", \"bbb\"]}")
        XCTAssertFalse(c.appliesToEveryPaidTool)
        XCTAssertEqual(c.toolIds, ["aaa", "bbb"])
        XCTAssertEqual(c.appliesToLabel, "2 tools")
    }

    func testMissingFieldIsNoBinding() throws {
        // A wheel older than 0.98.0 sends no tool_ids at all.
        let c = try decode("{\(Self.base)}")
        XCTAssertEqual(c.toolIds, [])
        XCTAssertEqual(c.appliesToLabel, "No tool yet")
    }

    func testBindingRoundTripsThroughThePicker() {
        XCTAssertEqual(ToolBinding(toolIds: ["*"]).toolIds, ["*"])
        XCTAssertEqual(ToolBinding(toolIds: ["b", "a"]).toolIds, ["a", "b"])
        XCTAssertEqual(ToolBinding(toolIds: []).toolIds, [])

        var picked = ToolBinding(toolIds: ["a"])
        picked.everyPaidTool = true
        XCTAssertEqual(picked.toolIds, ["*"], "the wildcard stands alone")
    }

    func testCouponStepIsNoLongerOffered() {
        for category in ConstraintCatalog.categories {
            XCTAssertFalse(ConstraintCatalog.specs(in: category).contains { $0.type == .coupon })
        }
        XCTAssertNotNil(ConstraintCatalog.spec(for: .coupon), "an authored step still renders")
        XCTAssertFalse(ConstraintCatalog.promptReference.contains("`coupon`"))
    }
}
