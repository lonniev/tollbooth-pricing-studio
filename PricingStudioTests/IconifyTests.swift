import XCTest
@testable import PricingStudio

/// The avatar catalog fetches a page of Iconify icons in one request, and keeps only real SVGs.
final class IconifyTests: XCTestCase {
    func testAnIconURLNamesItsCollectionAndIcon() throws {
        let url = try XCTUnwrap(AvatarCatalog.iconURL(prefix: "fluent-emoji-flat", name: "top-hat"))
        XCTAssertEqual(Iconify.icon(of: url)?.prefix, "fluent-emoji-flat")
        XCTAssertEqual(Iconify.icon(of: url)?.name, "top-hat")
        XCTAssertNil(Iconify.icon(of: URL(string: "https://example.com/a/b.svg")!))
        XCTAssertNil(Iconify.icon(of: URL(string: "https://api.iconify.design/a/b.png")!))
    }

    func testAPageIsOneRequest() throws {
        let url = try XCTUnwrap(Iconify.batchURL(prefix: "noto", names: ["a", "b-c"]))
        XCTAssertEqual(url.absoluteString, "https://api.iconify.design/noto.json?icons=a,b-c")
    }

    func testABatchBecomesStandaloneSVGs() throws {
        let json = """
        {"prefix":"x","width":32,"height":32,"icons":{"hat":{"body":"<g/>"},"wide":{"body":"<p/>","width":48}},
         "aliases":{"cap":{"parent":"hat"}},"not_found":["gone"]}
        """
        let docs = Iconify.documents(from: Data(json.utf8))
        XCTAssertEqual(Set(docs.keys), ["hat", "wide", "cap"])
        let hat = String(decoding: try XCTUnwrap(docs["hat"]), as: UTF8.self)
        XCTAssertEqual(hat, #"<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32"><g/></svg>"#)
        XCTAssertTrue(String(decoding: try XCTUnwrap(docs["wide"]), as: UTF8.self).contains(#"viewBox="0 0 48 32""#))
        XCTAssertEqual(docs["cap"], docs["hat"])
        XCTAssertTrue(Iconify.documents(from: Data("error code: 1015".utf8)).isEmpty)
    }

    func testAnErrorPageIsNotAnSVG() {
        XCTAssertFalse(Iconify.isSVG(Data("error code: 1015".utf8)))
        XCTAssertTrue(Iconify.isSVG(Data(#"<?xml version="1.0"?><svg viewBox="0 0 1 1"/>"#.utf8)))
    }
}
