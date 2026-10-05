import Foundation

/// Pure planning rules for Operator Secrets rotation (issue #153).
///
/// A healthy operator used to offer only **Forget** (wipe all six secrets and
/// rebuild). The backend already merges partial courier replies — omitting a
/// field preserves it — so the UI only needs to (a) surface a Rotate control
/// when fields are already configured, and (b) put only the ticked fields into
/// the courier template.
///
/// This type is host-free so the selection / labeling / safety rules can be
/// unit-tested without a simulator.
public enum OperatorSecretRotation {

    /// A single secret the steward can deliver or rotate.
    public struct Field: Equatable, Sendable, Hashable {
        /// Wire key as reported by onboarding status (e.g. `btcpay_api_key`).
        public let key: String
        /// `secret` / `authority` / `identity` / …
        public let category: String
        /// Whether the field is already vaulted (`configured`) or still empty.
        public let isConfigured: Bool
        /// Optional lifecycle hint (`set_once` | `dynamic`); unused for gating.
        public let lifecycle: String?

        public init(
            key: String,
            category: String = "secret",
            isConfigured: Bool,
            lifecycle: String? = nil
        ) {
            self.key = key
            self.category = category
            self.isConfigured = isConfigured
            self.lifecycle = lifecycle
        }
    }

    /// Whether the courier control is establishing missing secrets or rotating
    /// already-vaulted ones. Drives the button label and default selection.
    public enum Mode: String, Equatable, Sendable {
        /// At least one required/optional secret is missing → deliver those.
        case deliver
        /// Everything is present → rotate a steward-chosen subset.
        case rotate
    }

    /// Plan produced from the latest onboarding status + optional user ticks.
    public struct Plan: Equatable, Sendable {
        public let mode: Mode
        /// Fields the steward may tick (secrets only).
        public let candidates: [Field]
        /// Keys that will go into the courier template.
        public let selectedKeys: [String]
        /// Button label: "Deliver" or "Rotate".
        public let buttonLabel: String
        /// True when the courier can be opened with the current selection.
        public let canBegin: Bool

        public init(
            mode: Mode,
            candidates: [Field],
            selectedKeys: [String],
            buttonLabel: String,
            canBegin: Bool
        ) {
            self.mode = mode
            self.candidates = candidates
            self.selectedKeys = selectedKeys
            self.buttonLabel = buttonLabel
            self.canBegin = canBegin
        }
    }

    // MARK: - Planning

    /// Build a courier plan from onboarding fields.
    ///
    /// - Parameters:
    ///   - configured: fields already vaulted.
    ///   - missing: required fields still empty.
    ///   - optionalMissing: optional fields still empty.
    ///   - selectedKeys: steward ticks. In `.deliver` mode this is ignored and
    ///     every missing secret is selected. In `.rotate` mode, only ticked
    ///     keys that appear in `configured` secrets are kept; default is none
    ///     so an accidental send does nothing.
    public static func plan(
        configured: [Field],
        missing: [Field],
        optionalMissing: [Field] = [],
        selectedKeys: Set<String> = []
    ) -> Plan {
        let missingSecrets = (missing + optionalMissing).filter { isSecret($0) }
        let configuredSecrets = configured.filter { isSecret($0) }

        if !missingSecrets.isEmpty {
            // Deliver: every missing secret goes out. No tick UI required —
            // the operator cannot come online without them.
            let keys = missingSecrets.map(\.key)
            return Plan(
                mode: .deliver,
                candidates: missingSecrets,
                selectedKeys: keys,
                buttonLabel: "Deliver",
                canBegin: !keys.isEmpty
            )
        }

        // Rotate: only configured secrets are candidates. Default selection is
        // empty so a mis-tap cannot clobber a live vault.
        let allowed = Set(configuredSecrets.map(\.key))
        let picked = configuredSecrets
            .map(\.key)
            .filter { selectedKeys.contains($0) && allowed.contains($0) }
        return Plan(
            mode: .rotate,
            candidates: configuredSecrets,
            selectedKeys: picked,
            buttonLabel: "Rotate",
            canBegin: !picked.isEmpty
        )
    }

    /// Convenience: plan a single-field rotate (per-row Rotate control).
    public static func planSingleRotation(
        fieldKey: String,
        configured: [Field]
    ) -> Plan {
        plan(
            configured: configured,
            missing: [],
            optionalMissing: [],
            selectedKeys: [fieldKey]
        )
    }

    // MARK: - Display

    /// Humanize a wire field key: `btcpay_api_key` → `Btcpay Api Key`.
    public static func fieldLabel(_ field: String) -> String {
        field.replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Labels suitable for `CourierParams.missingSecrets` — humanized keys in
    /// the order of `plan.selectedKeys`.
    public static func courierSecretLabels(for plan: Plan) -> [String] {
        plan.selectedKeys.map(fieldLabel)
    }

    // MARK: - Copy

    /// Explain-phase body for the Secure Courier card. Rotate copy stresses
    /// that only the listed fields go out and that omitting a field preserves it.
    public static func explainCopy(mode: Mode, operatorName: String) -> String {
        switch mode {
        case .deliver:
            return "In order to come online, **\(operatorName)** needs the credentials below."
        case .rotate:
            return "Rotate only the secrets listed below for **\(operatorName)**. Untouched vaulted secrets stay as they are — omit a field to preserve it."
        }
    }

    /// Ready-phase instruction shown after the channel opens.
    public static func readyCopy(mode: Mode) -> String {
        switch mode {
        case .deliver:
            return "Fill in the listed fields and send your reply. Then tap Collect. Only fields you fill are written; leave any you are not setting blank."
        case .rotate:
            return "Fill in only the listed fields and send your reply. Then tap Collect. Do not paste a full template back — omitted fields keep their current values."
        }
    }

    /// Collect-failed hint. Never says "all fields filled in" — that copy was
    /// the trap that encouraged pasting placeholders over live secrets.
    public static func collectFailedCopy(mode: Mode, poison: String) -> String {
        switch mode {
        case .deliver:
            return "Make sure you replied to the DM with phrase \"\(poison)\" and filled the listed fields (leave any you are not setting blank)."
        case .rotate:
            return "Make sure you replied to the DM with phrase \"\(poison)\" and filled only the fields you meant to rotate. Omitted fields are preserved."
        }
    }

    // MARK: - Helpers

    private static func isSecret(_ field: Field) -> Bool {
        // Onboarding marks operator vault secrets as category "secret". Empty
        // category is treated as secret so a partial decode still rotates.
        let cat = field.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return cat.isEmpty || cat == "secret"
    }
}
