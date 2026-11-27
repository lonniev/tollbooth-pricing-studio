import XCTest
@testable import PricingStudio

/// The chat renderer: tool status lines collapse into one chip row, and a
/// pipe table parses into a header and rows.
final class MarkdownSegmentTests: XCTestCase {

    func testAdjacentStatusLinesCollapseIntoOneSegment() {
        let text = "*Consulting Operator…*\n\n*Consulting Operator…*\n\n_Summary updated._\n\nI've surveyed the catalog."
        let segments = MarkdownContentView.parseMarkdownSegments(text)
        XCTAssertEqual(segments.count, 2)
        guard case .status(let labels) = segments[0].kind else {
            return XCTFail("first segment should be status")
        }
        XCTAssertEqual(labels, ["Operator", "Operator", "Summary"])
        XCTAssertEqual(segments[1].content, "I've surveyed the catalog.")
    }

    func testProseItalicsAreNotStatus() {
        XCTAssertNil(MarkdownContentView.statusLabel("*Consulting is a trade.*"))
        XCTAssertNil(MarkdownContentView.statusLabel("_Summary of findings._"))
    }

    func testTableParsesHeaderAndRows() {
        let text = "| Category | Count |\n|---|---|\n| free | 43 |\n| read | 12 |"
        let segments = MarkdownContentView.parseMarkdownSegments(text)
        guard segments.count == 1, case .table(let header, let rows) = segments[0].kind else {
            return XCTFail("expected one table")
        }
        XCTAssertEqual(header, ["Category", "Count"])
        XCTAssertEqual(rows, [["free", "43"], ["read", "12"]])
    }
}
