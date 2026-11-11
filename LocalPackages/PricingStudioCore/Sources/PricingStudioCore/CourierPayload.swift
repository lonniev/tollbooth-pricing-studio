import Foundation

/// A Secure Courier request, read from the private tags of its NIP-17 message.
///
/// The request's kind 14 rumor carries a `form` tag (JSON Schema, see
/// `CourierForm`) and, from a signing operator, an `attestation` tag. The
/// message's text body is a fallback for other Nostr clients and is never
/// parsed here. The reply is a JSON object of string values, sent with an
/// `e` tag naming the request.
public struct CourierPayload: Sendable {

    /// A field the patron fills in, with its current value.
    public struct Field: Identifiable, Sendable {
        public let property: CourierForm.Property
        public var value: String

        public var id: String { property.key }
        public var key: String { property.key }

        public init(property: CourierForm.Property, value: String) {
            self.property = property
            self.value = value
        }

        /// Whether the field is still empty.
        public var needsInput: Bool {
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        /// Why the current value breaks the field's rules, if it does.
        public var problem: String? { property.problem(with: value) }
    }

    public let form: CourierForm
    /// The input fields, in the operator's order, with their current values.
    public var fields: [Field]
    /// The one-time anti-replay code the reply must echo.
    public let nonce: String
    /// The relay the courier listens on. The reply must be published there.
    public let rendezvousRelay: URL
    /// The operator's signed provenance attestation (a kind 27235 event), or
    /// nil when the request carries none — which must render amber, never green.
    public let attestationJSON: String?
    /// The request's rumor id, quoted in the reply's `e` tag.
    public let requestId: String

    public init(
        form: CourierForm, fields: [Field], nonce: String, rendezvousRelay: URL,
        attestationJSON: String?, requestId: String
    ) {
        self.form = form
        self.fields = fields
        self.nonce = nonce
        self.rendezvousRelay = rendezvousRelay
        self.attestationJSON = attestationJSON
        self.requestId = requestId
    }

    /// An approval asks for the signed reply itself, not for typed values.
    public var isApproval: Bool { form.kind == .approval }

    /// Fields the patron filled (non-empty).
    public var filledFields: [Field] { fields.filter { !$0.needsInput } }

    /// Per-field problems, keyed by field key.
    public var problems: [String: String] {
        var found: [String: String] = [:]
        for field in fields {
            if let problem = field.problem { found[field.key] = problem }
        }
        return found
    }

    /// A reply is sendable once at least one field is filled and none breaks
    /// its rules. Partial deliveries are allowed: the operator merges them
    /// into what it already holds, so one new secret can be sent alone.
    public var canSend: Bool { !filledFields.isEmpty && problems.isEmpty }

    // MARK: - Reading

    /// Read a courier request from a message's rumor tags.
    ///
    /// Returns nil unless the tags hold exactly one `form` that is a courier
    /// form with a non-empty nonce and a ws/wss rendezvous relay.
    public static func parse(tags: [[String]], requestId: String) -> CourierPayload? {
        let forms = tags.filter { $0.first == "form" && $0.count > 1 }
        guard forms.count == 1, let form = CourierForm.parse(forms[0][1]) else { return nil }

        guard let nonce = form.property("nonce")?.constant, !nonce.isEmpty,
              let relayText = form.property("rendezvous_relay")?.constant,
              let relay = URL(string: relayText),
              let scheme = relay.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss" else { return nil }

        let attestations = tags.filter { $0.first == "attestation" && $0.count > 1 }
        let fields = form.properties
            .filter(\.isInput)
            .map { Field(property: $0, value: $0.defaultValue ?? "") }

        return CourierPayload(
            form: form,
            fields: fields,
            nonce: nonce,
            rendezvousRelay: relay,
            attestationJSON: attestations.count == 1 ? attestations[0][1] : nil,
            requestId: requestId
        )
    }

    // MARK: - Replying

    /// The reply's content: a JSON object of the filled fields plus every
    /// fixed control value (nonce, rendezvous relay). Unfilled fields are left
    /// out so a partial reply never overwrites secrets the patron didn't touch.
    public func replyContent() -> String {
        var object: [String: String] = [:]
        for field in filledFields {
            object[field.key] = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for property in form.properties {
            if let constant = property.constant { object[property.key] = constant }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// This approval, answered: every empty field that offers no choices is
    /// filled with "approved". For an approval the value is immaterial — the
    /// signed reply is the proof — so only the offered choices (such as how
    /// long to remember it) are the patron's to make.
    public func approved() -> CourierPayload {
        var answered = self
        answered.fields = fields.map { field in
            var field = field
            if field.needsInput, field.property.examples.isEmpty, field.property.allowed.isEmpty {
                field.value = "approved"
            }
            return field
        }
        return answered
    }

    /// Set a field's value by key, when the form has that field.
    public func setting(_ key: String, to value: String) -> CourierPayload {
        var updated = self
        updated.fields = fields.map { field in
            var field = field
            if field.key == key { field.value = value }
            return field
        }
        return updated
    }

    /// The reply's private rumor tags: an `e` tag naming this request.
    public var replyTags: [[String]] {
        requestId.isEmpty ? [] : [["e", requestId]]
    }

    // MARK: - Recognising courier traffic

    /// The field count of an outbound courier reply, or nil when *content*
    /// is not one. A courier reply is a JSON object of strings that echoes a
    /// `nonce`. The relay echo of our own reply arrives as a NIP-04 copy with
    /// no tags, so the content's shape is the only thing to read.
    public static func replyFieldCount(_ content: String) -> Int? {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("{"),
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["nonce"] is String,
              object.values.allSatisfy({ $0 is String }) else { return nil }
        return object.keys.filter { $0 != "nonce" && $0 != "rendezvous_relay" }.count
    }

    /// Whether a message is courier traffic, whose content must stay out of
    /// notifications and logs: a request with a `form` tag, a courier reply,
    /// or the text-fallback copy of a request (its NIP-04 twin carries no
    /// tags, so the delimiter is the only sign).
    public static func isCourierTraffic(content: String, tags: [[String]]) -> Bool {
        tags.contains { $0.first == "form" }
            || replyFieldCount(content) != nil
            || content.contains("@@@")
    }

    // MARK: - The text twin of a request

    /// The nonce a request's form carries, or nil when *tags* hold no
    /// courier form.
    public static func formNonce(tags: [[String]]) -> String? {
        parse(tags: tags, requestId: "")?.nonce
    }

    /// The nonce written in a request's text body (`nonce = @@@…@@@`), or nil
    /// when the body names none.
    public static func twinNonce(content: String, delimiter: String = "@@@") -> String? {
        guard !delimiter.isEmpty else { return nil }
        for line in content.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "nonce" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix(delimiter), value.hasSuffix(delimiter),
                  value.count > delimiter.count * 2 else { continue }
            let nonce = String(value.dropFirst(delimiter.count).dropLast(delimiter.count))
            return nonce.isEmpty ? nil : nonce
        }
        return nil
    }

    /// The nonce of a request's text-only copy: a message with no form tag
    /// whose body names a nonce. The courier sends every request twice, as a
    /// form and as this text copy; the form is the one to show.
    public static func textTwinNonce(content: String, tags: [[String]]) -> String? {
        guard !tags.contains(where: { $0.first == "form" }) else { return nil }
        return twinNonce(content: content)
    }
}
