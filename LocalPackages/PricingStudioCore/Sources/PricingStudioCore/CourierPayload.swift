import Foundation

/// Parsed representation of a Secure Courier DM payload.
///
/// Extracts the `key = @@@value@@@` credential fields, the greeting preamble,
/// the anti-replay poison, and the provenance metadata from a raw DM string.
/// Reusable across PricingStudio and future Patron app.
public struct CourierPayload: Sendable {

    /// A single credential field extracted from the payload.
    public struct Field: Identifiable, Sendable {
        public let id = UUID()
        public let key: String
        public var value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }

        /// Whether the current value still looks like a placeholder or is empty.
        public var needsInput: Bool {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || (trimmed.hasPrefix("PASTE_YOUR_") && trimmed.hasSuffix("_HERE"))
        }
    }

    /// Provenance metadata from the `--- Message Provenance ---` section.
    public struct Provenance: Sendable {
        public var service: String?
        public var operatorNpub: String?
        public var sent: String?
        public var protocolVersion: String?
        /// The `Delivery key:` line — present only on self-addressed DMs, where
        /// relays require the request be delivered from a distinct ephemeral
        /// key. Its authority is proven by `attestationJSON`, not by itself.
        public var deliveryKey: String?
        /// The `Reason:` line — the Operator's stated human-readable purpose
        /// ("I'm working on your request XYZ …"), wheel v0.66.0+. The plaintext
        /// copy is convenience for display; the trustworthy value is the
        /// signature-bound `reason` tag on the attestation (see ProofProvenance).
        public var reason: String?

        public init(service: String? = nil, operatorNpub: String? = nil, sent: String? = nil, protocolVersion: String? = nil, deliveryKey: String? = nil, reason: String? = nil) {
            self.service = service
            self.operatorNpub = operatorNpub
            self.sent = sent
            self.protocolVersion = protocolVersion
            self.deliveryKey = deliveryKey
            self.reason = reason
        }
    }

    /// Text before the `--- Credential Payload ---` section.
    public var greeting: String

    /// The `key = @@@value@@@` fields in order of appearance.
    public var fields: [Field]

    /// The anti-replay poison field (if present), separated from editable fields.
    public var poison: Field?

    /// The rendezvous relay the courier published the challenge on. The
    /// responder MUST publish their reply to this exact relay so the
    /// courier's listener finds it — sender and receiver can't disagree
    /// when the relay URL is in the wire data. Present when the wheel
    /// is v0.39.0+; absent on older challenges.
    public var rendezvousRelay: Field?

    /// Metadata from the `--- Message Provenance ---` section.
    public var provenance: Provenance

    /// The raw JSON of the Operator provenance attestation (`--- Operator
    /// Attestation ---`), when the wheel embeds one. A signed kind-27235 event
    /// that binds the delivery key, subject, service, and one-time challenge to
    /// the Operator's registered identity. `nil` on legacy (pre-attestation)
    /// DMs — absence must render amber, never green (never trusted as green).
    public var attestationJSON: String?

    /// The original raw DM text.
    public let rawText: String

    public init(greeting: String, fields: [Field], poison: Field?, rendezvousRelay: Field?, provenance: Provenance, attestationJSON: String? = nil, rawText: String) {
        self.greeting = greeting
        self.fields = fields
        self.poison = poison
        self.rendezvousRelay = rendezvousRelay
        self.provenance = provenance
        self.attestationJSON = attestationJSON
        self.rawText = rawText
    }

    /// Whether this payload contains any `@@@` credential fields.
    public var hasCredentials: Bool { !fields.isEmpty }

    /// Whether all required fields have been filled in (non-placeholder).
    public var isComplete: Bool {
        fields.allSatisfy { !$0.needsInput }
    }

    /// Fields the operator actually filled (non-placeholder, non-empty).
    public var filledFields: [Field] {
        fields.filter { !$0.needsInput }
    }

    /// A reply is sendable once at least one field is filled. Partial
    /// deliveries are allowed — the backend merges them into the vault and
    /// leaves untouched whatever you don't send — so you can set just one
    /// new secret (e.g. an Anthropic key) without re-entering the others.
    public var canSend: Bool { !filledFields.isEmpty }

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
    public static func parse(_ text: String) -> CourierPayload? {
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

        // Separate the dpop_token, rendezvous_relay, and attestation from
        // editable fields. All are protocol-control metadata, not user-editable
        // values. (Wheel 0.57.0+ renamed the credential-DM control field
        // poison → dpop_token; the attestation arrived with proof provenance.)
        let poison = allFields.first(where: { $0.key == "dpop_token" })
        let rendezvousRelay = allFields.first(where: { $0.key == "rendezvous_relay" })
        let attestationJSON = allFields.first(where: { $0.key == "attestation" })?.value
        let controlKeys: Set<String> = ["dpop_token", "rendezvous_relay", "attestation"]
        let fields = allFields.filter { !controlKeys.contains($0.key) }

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
            rendezvousRelay: rendezvousRelay,
            provenance: provenance,
            attestationJSON: attestationJSON,
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
            } else if trimmed.hasPrefix("Delivery key:") {
                prov.deliveryKey = String(trimmed.dropFirst(13)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Sent:") {
                prov.sent = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Protocol:") {
                prov.protocolVersion = String(trimmed.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Reason:") {
                prov.reason = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
        }

        return prov
    }

    // MARK: - Serialization

    /// Re-serialize the fields back into `key = @@@value@@@` format for sending as a DM reply.
    /// Only FILLED fields are emitted — unfilled placeholders are omitted so a
    /// partial reply doesn't overwrite vaulted secrets you didn't touch (the
    /// backend merges what it receives). The rendezvous_relay is protocol-
    /// control metadata for the sender's listener — not echoed back.
    public func serialize() -> String {
        var lines: [String] = []
        for field in filledFields {
            lines.append("  \(field.key) = @@@\(field.value)@@@")
        }
        if let poison {
            lines.append("  \(poison.key) = @@@\(poison.value)@@@")
        }
        return lines.joined(separator: "\n")
    }
}
