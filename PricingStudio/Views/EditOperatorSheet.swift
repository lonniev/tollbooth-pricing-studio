import SwiftUI

struct EditOperatorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    var viewModel: OperatorCollectionViewModel
    var pricingVM: PricingViewModel?
    let operator_: Operator
    @State private var showingSwitchSheet = false

    // Same field order as AddOperatorSheet, with one exception:
    // npub is read-only here. Changing the npub of an existing
    // Operator record would orphan its Keychain entries, Authority
    // ledger row, Neon tenant, and any local references — so the
    // npub stays fixed for the life of the record.
    @State private var displayName: String
    @State private var nsec: String = ""
    @State private var showNsec = false
    @State private var hasStoredNsec = false
    @State private var mcpEndpointURL: String
    @State private var nip05: String

    init(viewModel: OperatorCollectionViewModel, operator_: Operator, pricingVM: PricingViewModel? = nil) {
        self.viewModel = viewModel
        self.pricingVM = pricingVM
        self.operator_ = operator_
        self._displayName = State(initialValue: operator_.displayName)
        self._nip05 = State(initialValue: operator_.nip05 ?? "")
        self._mcpEndpointURL = State(initialValue: operator_.mcpEndpointURL ?? "")
    }

    private var trimmedURL: String {
        mcpEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var urlLooksValid: Bool {
        trimmedURL.hasPrefix("http://") || trimmedURL.hasPrefix("https://")
    }

    private var urlChanged: Bool {
        trimmedURL != (operator_.mcpEndpointURL ?? "")
    }

    /// Edit-time validation:
    ///   - Display Name and MCP URL are required (mirrors Add).
    ///   - Save is enabled only when those are satisfied AND at least
    ///     one field actually changed (no-op saves are uninteresting).
    private var canSave: Bool {
        let nameOK = !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let urlOK = urlLooksValid
        let nameChanged = displayName != operator_.displayName
        let nip05Changed = nip05.trimmingCharacters(in: .whitespacesAndNewlines) != (operator_.nip05 ?? "")
        let nsecChanged = !nsec.isEmpty
        return nameOK && urlOK && (nameChanged || nip05Changed || nsecChanged || urlChanged)
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

                // 2. npub (required, read-only) ---------------------------
                Section {
                    Text(operator_.npub)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                } header: {
                    requiredHeader("Operator npub")
                } footer: {
                    Text("The npub cannot be changed for an existing Operator record.")
                }

                // 3. nsec (optional, password) ----------------------------
                Section {
                    HStack {
                        if showNsec {
                            TextField("nsec1…", text: $nsec, prompt: Text("nsec1… (leave blank to keep existing)"))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .monospaced()
                                .font(.callout)
                        } else {
                            SecureField("nsec1…", text: $nsec, prompt: Text("nsec1… (leave blank to keep existing)"))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .monospaced()
                                .font(.callout)
                        }
                        Button {
                            showNsec.toggle()
                        } label: {
                            Image(systemName: showNsec ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    if hasStoredNsec && nsec.isEmpty {
                        Label("Stored in Keychain", systemImage: "checkmark.shield.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                } header: {
                    Text("Secret Key (nsec) — Optional")
                } footer: {
                    Text("Leave blank to catalogue an operator you do not control. The nsec is needed only when you sign actions on this operator's behalf. Stored in the device Keychain when provided.")
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
                    } else if urlChanged {
                        Label("URL changed — operator will need to re-register with its Authority", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Text("The operator's public SSE endpoint.")
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

                // 6. Registration switch — shown only when a PricingViewModel
                //    is available (the sheet has to feed RegisterOperatorSheet).
                if pricingVM != nil {
                    Section {
                        Button {
                            showingSwitchSheet = true
                        } label: {
                            Label(
                                operator_.authorityNpub == nil
                                    ? "Request Registration…"
                                    : "Switch Authority…",
                                systemImage: "arrow.triangle.swap"
                            )
                        }
                    } footer: {
                        Text(operator_.authorityNpub == nil
                             ? "This operator has no Authority. Pick one to request registration."
                             : "Move this operator's registration to a different Authority. Deregister-then-register runs as a single step.")
                    }
                }

                NotificationToggleSection(npub: operator_.npub)
            }
            .navigationTitle("Edit Operator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveAndDismiss() }
                        .disabled(!canSave)
                }
            }
            .task {
                hasStoredNsec = KeychainService.loadNsec(forNpub: operator_.npub) != nil
            }
            .sheet(isPresented: $showingSwitchSheet) {
                if let pricingVM {
                    RegisterOperatorSheet(operatorTarget: operator_, pricingVM: pricingVM)
                }
            }
        }
    }

    @ViewBuilder
    private func requiredHeader(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Text("*")
                .foregroundStyle(.red)
                .accessibilityLabel("required")
        }
    }

    private func saveAndDismiss() {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNip05 = nip05.trimmingCharacters(in: .whitespacesAndNewlines)
        operator_.nip05 = trimmedNip05.isEmpty ? nil : trimmedNip05

        if trimmedName != operator_.displayName {
            viewModel.updateOperator(
                operator_,
                displayName: trimmedName,
                context: modelContext
            )
        }

        if urlChanged {
            operator_.mcpEndpointURL = trimmedURL.isEmpty ? nil : trimmedURL
            // URL changed — operator must re-register with its Authority.
            operator_.authorityNpub = nil
            try? modelContext.save()
        }

        let trimmedNsec = nsec.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNsec.isEmpty {
            try? KeychainService.saveNsec(trimmedNsec, forNpub: operator_.npub)
        }
        dismiss()
    }
}
