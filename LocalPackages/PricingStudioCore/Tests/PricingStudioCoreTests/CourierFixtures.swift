import Foundation
import XCTest

/// Golden courier forms copied from tollbooth-dpyc
/// `tests/fixtures/courier_form/`. Both repos test against the same files, so
/// a change to the form's shape breaks a test on each side.
enum CourierFixtures {

    /// A fixture's JSON, compacted to one line as the SDK puts it in the tag.
    /// *edit* changes the decoded form first; compare structures, never text,
    /// because serialized JSON has no fixed key order.
    static func text(_ name: String, edit: (inout [String: Any]) -> Void = { _ in }) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/courier_form")
        )
        var form = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        edit(&form)
        let data = try JSONSerialization.data(withJSONObject: form)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    /// Set one keyword on one property of a decoded form.
    static func set(_ form: inout [String: Any], property: String, _ keyword: String, _ value: Any) {
        var properties = form["properties"] as? [String: Any] ?? [:]
        var spec = properties[property] as? [String: Any] ?? [:]
        spec[keyword] = value
        properties[property] = spec
        form["properties"] = properties
    }

    /// A reply's JSON content as a string dictionary.
    static func object(_ content: String) throws -> [String: String] {
        let data = try XCTUnwrap(content.data(using: .utf8))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: String])
    }
}
