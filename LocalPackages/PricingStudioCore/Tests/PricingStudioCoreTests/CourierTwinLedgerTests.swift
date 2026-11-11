import XCTest
@testable import PricingStudioCore

final class CourierTwinLedgerTests: XCTestCase {

    func testEachRequestCountsOnceWhicheverCopyComesFirst() {
        var ledger = CourierTwinLedger()
        XCTAssertTrue(ledger.counts(nonce: "neat-zero-14"))
        XCTAssertFalse(ledger.counts(nonce: "neat-zero-14"))
        XCTAssertTrue(ledger.counts(nonce: "bold-hawk-42"))
    }

    func testOrdinaryMessagesAlwaysCount() {
        var ledger = CourierTwinLedger()
        XCTAssertTrue(ledger.counts(nonce: nil))
        XCTAssertTrue(ledger.counts(nonce: nil))
    }

    func testABatchCountsTheFormNotItsTextCopy() {
        var ledger = CourierTwinLedger()
        let ids = ledger.countedIds([
            (id: "text", formNonce: nil, textNonce: "n1"),
            (id: "form", formNonce: "n1", textNonce: nil),
            (id: "chat", formNonce: nil, textNonce: nil),
        ])
        XCTAssertEqual(ids, ["form", "chat"])
        XCTAssertTrue(ledger.countedIds([(id: "late-text", formNonce: nil, textNonce: "n1")]).isEmpty)
    }
}
