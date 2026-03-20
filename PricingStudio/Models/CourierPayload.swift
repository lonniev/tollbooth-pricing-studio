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

        /// Whether the current value still looks like a placeholder or is empty.
        var needsInput: Bool {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || (trimmed.hasPrefix("PASTE_YOUR_") && trimmed.hasSuffix("_HERE"))
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
        // Extract greeting (text before "--- Credential Payload ---")
        let greeting: String
        let fieldSearchText: String  // only search for fields in the payload section

        if let payloadHeader = text.range(of: "--- Credential Payload ---") {
            greeting = String(text[text.startIndex..<payloadHeader.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Restrict field extraction to text after the header (and before provenance)
            let afterHeader = String(text[payloadHeader.upperBound...])
            if let provenanceHeader = afterHeader.range(of: "--- Message Provenance ---") {
                fieldSearchText = String(afterHeader[afterHeader.startIndex..<provenanceHeader.lowerBound])
            } else {
                fieldSearchText = afterHeader
            }
        } else {
            // No section header — fall back to searching the full text
            greeting = ""
            fieldSearchText = text
        }

        let nsFieldText = fieldSearchText as NSString
        let fieldRange = NSRange(location: 0, length: nsFieldText.length)
        let matches = fieldPattern.matches(in: fieldSearchText, range: fieldRange)

        guard !matches.isEmpty else { return nil }

        // Extract all key=@@@value@@@ fields from the payload section only
        var allFields: [Field] = []
        for match in matches {
            guard let keyRange = Range(match.range(at: 1), in: fieldSearchText),
                  let valueRange = Range(match.range(at: 2), in: fieldSearchText) else { continue }

            let key = String(fieldSearchText[keyRange]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(fieldSearchText[valueRange])
            // Strip newlines that mobile clients may inject
            let value = rawValue
                .replacingOccurrences(of: "\r\n", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .trimmingCharacters(in: .whitespaces)

            allFields.append(Field(key: key, value: value))
        }

        // Separate poison from editable fields
        let poison = allFields.first(where: { $0.key == "poison" })
        let fields = allFields.filter { $0.key != "poison" }

        // If no header was found, derive greeting from text before first field in full text
        var finalGreeting = greeting
        if greeting.isEmpty, let firstMatch = fieldPattern.firstMatch(
            in: text, range: NSRange(location: 0, length: (text as NSString).length)
        ) {
            let beforeField = (text as NSString).substring(to: firstMatch.range.location)
            finalGreeting = beforeField.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Extract provenance metadata
        let provenance = parseProvenance(from: text)

        return CourierPayload(
            greeting: finalGreeting,
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
