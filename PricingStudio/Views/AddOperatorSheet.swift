import SwiftUI
import UIKit

struct AddOperatorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    var viewModel: OperatorCollectionViewModel

    // Field order per user spec:
    //   Display Name (required) → npub (required) → nsec (optional,
    //   password) → MCP URL (required) → NIP-05 (optional).
    //
    // The nsec is genuinely optional. The user may be cataloguing an
    // operator they do NOT control (e.g. building a directory entry).
    // Only the npub + MCP URL + display name are needed to refer to
    // such an operator; nsec is required only for signing actions on
    // its behalf (which a non-controlling cataloguer wouldn't do).
    @State private var displayName: String = ""
    @State private var npub: String = ""
    @State private var nsec: String = ""
    @State private var mcpEndpointURL: String = ""
    @State private var nip05: String = ""

    @State private var derivedNpub: String?
    @State private var keyError: String?
    @State private var generatedKeys = false
    @State private var copiedNsec = false

    // Oracle lookup state
    @State private var oracleLookupInFlight = false
    @State private var oracleLookupNote: String?

    /// The npub field's authoritative value:
    /// - if the user edited an nsec that derived a valid npub, the derived
    ///   value wins (and the npub field is locked to it for visibility);
    /// - otherwise, whatever the user typed.
    private var effectiveNpub: String {
        let derived = derivedNpub?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !derived.isEmpty { return derived }
        return npub.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedURL: String {
        mcpEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var npubLooksValid: Bool {
        let n = effectiveNpub
        return n.hasPrefix("npub1") && n.count > 10
    }

    private var urlLooksValid: Bool {
        let u = trimmedURL
        return u.hasPrefix("http://") || u.hasPrefix("https://")
    }

    private var canLookUpInOracle: Bool {
        npubLooksValid && !oracleLookupInFlight
    }

    /// Add button is enabled only when every REQUIRED field is satisfied.
    /// nsec and NIP-05 are optional — the button stays enabled even if
    /// those are blank.
    private var isValid: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && npubLooksValid
            && urlLooksValid
    }

    var body: some View {
        NavigationStack {
            Form {

                // 1. Display Name (required) ------------------------------
                Section {
                    TextField("Friendly name", text: $displayName)
                        .textContentType(.username)
                } header: {
                    requiredHeader("Display Name")
                } footer: {
                    Text("How this operator appears in lists, charts, and selectors.")
                }

                // 2. npub (required) --------------------------------------
                Section {
                    TextField("npub1…", text: $npub, prompt: Text("npub1…"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .monospaced()
                        .font(.callout)
                        .disabled(derivedNpub != nil)
                        .foregroundStyle(derivedNpub != nil ? .secondary : .primary)
                    if canLookUpInOracle {
                        Button {
                            Task { await lookUpInOracle() }
                        } label: {
                            HStack {
                                if oracleLookupInFlight {
                                    ProgressView().padding(.trailing, 4)
                                }
                                Label("Look up in DPYC Oracle", systemImage: "magnifyingglass.circle")
                            }
                        }
                        .disabled(!canLookUpInOracle)
                    }
                } header: {
                    requiredHeader("Operator npub")
                } footer: {
                    if let derived = derivedNpub {
                        Label("Derived from nsec — locked", systemImage: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(derived)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    } else if let note = oracleLookupNote {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Type the npub directly, derive it by entering an nsec below, or look it up in the Oracle to auto-fill the other fields.")
                    }
                }

                // 3. nsec (optional, password) ----------------------------
                Section {
                    HStack {
                        SecureField("nsec1…", text: $nsec, prompt: Text("nsec1… (optional)"))
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .monospaced()
                            .font(.callout)
                            .onChange(of: nsec) { _, newValue in
                                if !generatedKeys {
                                    deriveNpubFromNsec(newValue)
                                }
                            }
                        if generatedKeys && !nsec.isEmpty {
                            Button {
                                UIPasteboard.general.string = nsec
                                copiedNsec = true
                            } label: {
                                Image(systemName: copiedNsec ? "checkmark" : "doc.on.doc")
                                    .foregroundStyle(copiedNsec ? .green : .secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("copyNsecButton")
                        }
                    }
                    Button {
                        generateNewKeys()
                    } label: {
                        Label("Generate new Nostr keys", systemImage: "key.fill")
                    }
                    .accessibilityIdentifier("generateKeysButton")
                    .disabled(generatedKeys)
                } header: {
                    Text("Secret Key (nsec) — Optional")
                } footer: {
                    if let error = keyError {
                        Text(error).foregroundStyle(.red)
                    } else if copiedNsec {
                        Label("Copied to clipboard — save this nsec in your vault now", systemImage: "exclamationmark.shield.fill")
                            .foregroundStyle(.orange)
                    } else if generatedKeys {
                        Label("npub derived from nsec — copy and save before dismissing", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else if derivedNpub != nil {
                        Label("npub derived from nsec", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("Leave blank to catalogue an operator you do not control. The nsec is needed only when you sign actions on this operator's behalf.")
                    }
                }

                // 4. MCP Endpoint URL (required) --------------------------
                Section {
                    TextField(
                        "MCP endpoint URL",
                        text: $mcpEndpointURL,
                        prompt: Text("https://my-service.fastmcp.app/mcp")
                    )
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .monospaced()
                        .font(.callout)
                } header: {
                    requiredHeader("MCP Endpoint URL")
                } footer: {
                    if mcpEndpointURL.isEmpty {
                        Label("Required — an Authority cannot register an operator without a public MCP endpoint.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if !urlLooksValid {
                        Label("Must start with http:// or https://", systemImage: "xmark.octagon")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("The operator's public SSE endpoint, e.g. https://optionality-mcp.fastmcp.app/mcp.")
                    }
                }

                // 5. NIP-05 Identity (optional) ---------------------------
                Section {
                    TextField(
                        "NIP-05 identity",
                        text: $nip05,
                        prompt: Text("user@domain.org")
                    )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .font(.callout)
                } header: {
                    Text("NIP-05 Identity — Optional")
                } footer: {
                    Text("Nostr-verifiable name (NIP-05). Lets clients confirm the npub belongs to a recognizable identity at a domain you control.")
                }
            }
            .navigationTitle("Add Operator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { saveAndDismiss() }
                        .disabled(!isValid)
                }
            }
        }
    }

    // MARK: - Required-field header styling

    @ViewBuilder
    private func requiredHeader(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Text("*")
                .foregroundStyle(.red)
                .accessibilityLabel("required")
        }
    }

    // MARK: - Save

    private func saveAndDismiss() {
        let finalNpub = effectiveNpub
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNsec = nsec.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNip05 = nip05.trimmingCharacters(in: .whitespacesAndNewlines)

        viewModel.addOperator(
            npub: finalNpub,
            displayName: trimmedName,
            mcpEndpointURL: trimmedURL,
            context: modelContext
        )
        if !trimmedNip05.isEmpty {
            viewModel.selectedOperator?.nip05 = trimmedNip05
            try? modelContext.save()
        }
        if !trimmedNsec.isEmpty {
            try? KeychainService.saveNsec(trimmedNsec, forNpub: finalNpub)
        }
        dismiss()
    }

    // MARK: - Key derivation

    private func generateNewKeys() {
        do {
            let keys = try NostrKeyService.generateKeyPair()
            nsec = keys.nsec
            npub = keys.npub
            derivedNpub = keys.npub
            keyError = nil
            generatedKeys = true
        } catch {
            keyError = "Key generation failed: \(error.localizedDescription)"
        }
    }

    private func deriveNpubFromNsec(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            derivedNpub = nil
            keyError = nil
            return
        }
        guard trimmed.hasPrefix("nsec1") else {
            derivedNpub = nil
            keyError = "Must start with nsec1"
            return
        }
        do {
            derivedNpub = try NostrKeyService.npubFromNsec(trimmed)
            npub = derivedNpub ?? ""
            keyError = nil
        } catch {
            derivedNpub = nil
            keyError = error.localizedDescription
        }
    }

    // MARK: - Oracle lookup

    /// Auto-fill displayName / mcpEndpointURL / nip05 from the DPYC Oracle's
    /// lookup_member result, if it has an entry for this npub. Only fills
    /// EMPTY fields — never overwrites user input. Silent on miss.
    private func lookUpInOracle() async {
        let target = effectiveNpub
        guard target.hasPrefix("npub1") else { return }
        oracleLookupInFlight = true
        oracleLookupNote = nil
        defer { oracleLookupInFlight = false }

        do {
            let oracleURL = try await RegistryService.resolveOracleURL()
            let response = try await MCPService().callToolGeneric(
                endpointURL: oracleURL,
                toolName: "lookup_member",
                arguments: ["npub": .string(target)]
            )
            guard let data = response.data(using: .utf8) else {
                oracleLookupNote = "No response from Oracle."
                return
            }
            // The Oracle wraps the record in {"result": <MemberRecord or message>}.
            // Try the wrapper first; fall through to a bare record decode.
            let record: MemberRecord? = {
                if let w = try? JSONDecoder().decode(OracleLookupResponse.self, from: data) {
                    if case .member(let r) = w.result { return r }
                    return nil
                }
                return try? JSONDecoder().decode(MemberRecord.self, from: data)
            }()
            guard let record else {
                oracleLookupNote = "npub is not in the DPYC community registry yet."
                return
            }
            if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                displayName = record.displayName
            }
            if mcpEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let url = record.services?.first?.url, !url.isEmpty {
                mcpEndpointURL = url
            }
            // nip05 isn't in MemberRecord today, but if it shows up in a
            // future schema rev, prefer the Oracle's value over the empty
            // user field. (No-op for now.)
            oracleLookupNote = "Filled from Oracle (role: \(record.role)). Review and edit as needed."
        } catch {
            oracleLookupNote = "Oracle lookup failed: \(error.localizedDescription)"
        }
    }
}
