import Foundation

/// Parsed representation of a Secure Courier DM payload.
///
/// Extracts the `key = @@@value@@@` credential fields, the greeting preamble,
/// the anti-replay poison, and the provenance metadata from a raw DM string.
/// Reusable across PricingStudio and future Patron app.
struct CourierPayload: Sendable {

    /// A single credential field extracted from the payload.
    struct Field: Identifiable, Sendable {
        let id = UUID()
        let key: String
        var value: String
        let isPlaceholder: Bool

        /// Whether the value looks like it still needs user input.
        var needsInput: Bool {
            isPlaceholder || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Provenance metadata from the `--- Message Provenance ---` section.
    struct Provenance: Sendable {
        var service: String?
        var operatorNpub: String?
        var sent: String?
        var protocolVersion: String?
    }

    /// Text before the `--- Credential Payload ---` section.
    var greeting: String

    /// The `key = @@@value@@@` fields in order of appearance.
    var fields: [Field]

    /// The anti-replay poison field (if present), separated from editable fields.
    var poison: Field?

    /// Metadata from the `--- Message Provenance ---` section.
    var provenance: Provenance

    /// The original raw DM text.
    let rawText: String

    /// Whether this payload contains any `@@@` credential fields.
    var hasCredentials: Bool { !fields.isEmpty }

    /// Whether all required fields have been filled in (non-placeholder).
    var isComplete: Bool {
        fields.allSatisfy { !$0.needsInput }
    }

    // MARK: - Parsing

    /// Regex matching `key = @@@value@@@` pairs.
    /// Tempered greedy token: matches any non-@ char, or @ not followed by @@.
    /// This mirrors the Python `_DELIMITED_FIELD` regex in nostr_credentials.py.
    private static let fieldPattern = try! NSRegularExpression(
        pattern: #"(\w+)\s*=\s*@@@((?:[^@]|@(?!@@))*)@@@"#,
        options: []
    )

    /// Try to parse a raw DM string as a Secure Courier payload.
    /// Returns `nil` if no `@@@` fields are found.
    static func parse(_ text: String) -> CourierPayload? {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = fieldPattern.matches(in: text, range: fullRange)

        guard !matches.isEmpty else { return nil }

        // Extract all key=@@@value@@@ fields
        var allFields: [Field] = []
        for match in matches {
            guard let keyRange = Range(match.range(at: 1), in: text),
                  let valueRange = Range(match.range(at: 2), in: text) else { continue }

            let key = String(text[keyRange]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(text[valueRange])
            // Strip newlines that mobile clients may inject
            let value = rawValue
                .replacingOccurrences(of: "\r\n", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .trimmingCharacters(in: .whitespaces)

            let isPlaceholder = value.hasPrefix("PASTE_YOUR_") && value.hasSuffix("_HERE")

            allFields.append(Field(key: key, value: value, isPlaceholder: isPlaceholder))
        }

        // Separate poison from editable fields
        let poison = allFields.first(where: { $0.key == "poison" })
        let fields = allFields.filter { $0.key != "poison" }

        // Extract greeting (text before "--- Credential Payload ---")
        let greeting: String
        if let payloadHeader = text.range(of: "--- Credential Payload ---") {
            greeting = String(text[text.startIndex..<payloadHeader.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let firstMatch = matches.first {
            // Fall back to text before first field
            let beforeField = nsText.substring(to: firstMatch.range.location)
            greeting = beforeField.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            greeting = ""
        }

        // Extract provenance metadata
        let provenance = parseProvenance(from: text)

        return CourierPayload(
            greeting: greeting,
            fields: fields,
            poison: poison,
            provenance: provenance,
            rawText: text
        )
    }

    /// Parse the `--- Message Provenance ---` section.
    private static func parseProvenance(from text: String) -> Provenance {
        var prov = Provenance()

        guard let provenanceStart = text.range(of: "--- Message Provenance ---") else {
            return prov
        }

        let provenanceText = String(text[provenanceStart.upperBound...])
        let lines = provenanceText.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Service:") {
                prov.service = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Operator:") {
                prov.operatorNpub = String(trimmed.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Sent:") {
                prov.sent = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Protocol:") {
                prov.protocolVersion = String(trimmed.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            }
        }

        return prov
    }

    // MARK: - Serialization

    /// Re-serialize the fields back into `key = @@@value@@@` format for sending as a DM reply.
    func serialize() -> String {
        var lines: [String] = []
        for field in fields {
            lines.append("  \(field.key) = @@@\(field.value)@@@")
        }
        if let poison {
            lines.append("  \(poison.key) = @@@\(poison.value)@@@")
        }
        return lines.joined(separator: "\n")
    }
}
