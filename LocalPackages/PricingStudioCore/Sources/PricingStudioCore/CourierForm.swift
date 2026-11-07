import Foundation

/// The form a Secure Courier request carries in its `form` rumor tag.
///
/// The SDK writes it as a flat JSON Schema (draft 2020-12) object of string
/// fields (`tollbooth.credential_templates.courier_form_schema`). This reader
/// accepts only that subset. Anything else — a nested object, a non-string
/// type — is not a courier form, and the message renders as plain text.
/// Unknown annotation keywords are ignored, as JSON Schema allows.
public struct CourierForm: Sendable, Equatable {

    /// Whether the patron types values in, or the reply itself is the answer.
    public enum Kind: String, Sendable {
        case credentials
        case approval
    }

    /// One field of the form.
    public struct Property: Sendable, Equatable, Identifiable {
        public let key: String
        public let title: String
        public let description: String?
        public let defaultValue: String?
        /// Suggested values (`examples`), offered as quick picks.
        public let examples: [String]
        /// The only values allowed (`enum`), when the form names them.
        public let allowed: [String]
        /// A fixed value (`const`) the reply echoes unchanged.
        public let constant: String?
        /// `writeOnly`: a secret, masked while typed and never shown back.
        public let isSecret: Bool
        public let isReadOnly: Bool
        public let isRequired: Bool
        public let minLength: Int?
        public let maxLength: Int?
        public let pattern: String?

        public var id: String { key }

        /// Whether the patron fills this field in (not a fixed control value).
        public var isInput: Bool { !isReadOnly && constant == nil }

        public init(
            key: String, title: String, description: String? = nil,
            defaultValue: String? = nil, examples: [String] = [], allowed: [String] = [],
            constant: String? = nil, isSecret: Bool = false, isReadOnly: Bool = false,
            isRequired: Bool = false, minLength: Int? = nil, maxLength: Int? = nil,
            pattern: String? = nil
        ) {
            self.key = key
            self.title = title
            self.description = description
            self.defaultValue = defaultValue
            self.examples = examples
            self.allowed = allowed
            self.constant = constant
            self.isSecret = isSecret
            self.isReadOnly = isReadOnly
            self.isRequired = isRequired
            self.minLength = minLength
            self.maxLength = maxLength
            self.pattern = pattern
        }

        /// Why *value* breaks this field's rules, or nil when it keeps them.
        /// An empty value is never an error here: a reply may leave fields
        /// out, and the operator merges what arrives.
        public func problem(with value: String) -> String? {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            if !allowed.isEmpty, !allowed.contains(text) {
                return "Choose one of: \(allowed.joined(separator: ", "))"
            }
            if let minLength, text.count < minLength {
                return "At least \(minLength) characters"
            }
            if let maxLength, text.count > maxLength {
                return "At most \(maxLength) characters"
            }
            if let pattern, text.range(of: pattern, options: .regularExpression) == nil {
                return "Not in the expected format"
            }
            return nil
        }
    }

    public let title: String
    public let description: String?
    public let service: String
    public let kind: Kind
    /// The delimiter a plain-text reply wraps each value in (`x-delimiter`).
    public let delimiter: String
    /// Fields in the operator's order (`propertyOrder`).
    public let properties: [Property]

    public init(
        title: String, description: String?, service: String, kind: Kind,
        delimiter: String, properties: [Property]
    ) {
        self.title = title
        self.description = description
        self.service = service
        self.kind = kind
        self.delimiter = delimiter
        self.properties = properties
    }

    public func property(_ key: String) -> Property? {
        properties.first { $0.key == key }
    }

    // MARK: - Reading

    /// Read a form from its JSON text, or nil when it is not a courier form.
    public static func parse(_ json: String) -> CourierForm? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "object",
              let rawProperties = root["properties"] as? [String: Any],
              let kindText = root["x-courier-kind"] as? String,
              let kind = Kind(rawValue: kindText) else { return nil }

        let required = Set(root["required"] as? [String] ?? [])
        var ordered: [(order: Int, property: Property)] = []
        for (key, raw) in rawProperties {
            guard let spec = raw as? [String: Any],
                  let property = readProperty(key: key, spec: spec, isRequired: required.contains(key))
            else { return nil }
            // Fields without a place (the control values) sort after the rest.
            ordered.append((spec["propertyOrder"] as? Int ?? Int.max, property))
        }
        ordered.sort { ($0.order, $0.property.key) < ($1.order, $1.property.key) }

        return CourierForm(
            title: root["title"] as? String ?? "",
            description: (root["description"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            service: root["x-service"] as? String ?? "",
            kind: kind,
            delimiter: root["x-delimiter"] as? String ?? "@@@",
            properties: ordered.map(\.property)
        )
    }

    /// One property, or nil when it falls outside the subset.
    private static func readProperty(key: String, spec: [String: Any], isRequired: Bool) -> Property? {
        guard spec["type"] as? String == "string" else { return nil }
        func strings(_ name: String) -> [String]? {
            guard let value = spec[name] else { return [] }
            return value as? [String]
        }
        guard let examples = strings("examples"), let allowed = strings("enum") else { return nil }
        if let constant = spec["const"], !(constant is String) { return nil }
        if let fallback = spec["default"], !(fallback is String) { return nil }
        return Property(
            key: key,
            title: (spec["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? key,
            description: (spec["description"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            defaultValue: spec["default"] as? String,
            examples: examples,
            allowed: allowed,
            constant: spec["const"] as? String,
            isSecret: spec["writeOnly"] as? Bool ?? false,
            isReadOnly: spec["readOnly"] as? Bool ?? false,
            isRequired: isRequired,
            minLength: spec["minLength"] as? Int,
            maxLength: spec["maxLength"] as? Int,
            pattern: spec["pattern"] as? String
        )
    }
}
