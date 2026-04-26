import SwiftUI

struct EditOperatorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    var viewModel: OperatorCollectionViewModel
    let operator_: Operator

    @State private var displayName: String
    @State private var nip05: String
    @State private var mcpEndpointURL: String
    @State private var nsec: String = ""
    @State private var showNsec = false
    @State private var hasStoredNsec = false

    init(viewModel: OperatorCollectionViewModel, operator_: Operator) {
        self.viewModel = viewModel
        self.operator_ = operator_
        self._displayName = State(initialValue: operator_.displayName)
        self._nip05 = State(initialValue: operator_.nip05 ?? "")
        self._mcpEndpointURL = State(initialValue: operator_.mcpEndpointURL ?? "")
    }

    private var urlChanged: Bool {
        let trimmed = mcpEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed != (operator_.mcpEndpointURL ?? "")
    }

    private var hasChanges: Bool {
        let nameChanged = !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && displayName != operator_.displayName
        let nip05Changed = nip05.trimmingCharacters(in: .whitespacesAndNewlines) != (operator_.nip05 ?? "")
        let nsecChanged = !nsec.isEmpty
        return nameChanged || nip05Changed || nsecChanged || urlChanged
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(operator_.npub)
                        .font(.callout)
                        .monospaced()
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Operator npub")
                } footer: {
                    Text("The npub cannot be changed.")
                }

                Section {
                    TextField("Display Name", text: $displayName)
                } header: {
                    Text("Display Name")
                }

                Section {
                    TextField("user@domain.org", text: $nip05)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .font(.callout)
                } header: {
                    Text("NIP-05 Identity")
                } footer: {
                    Text("Optional. Nostr-verifiable name.")
                }

                Section {
                    TextField("https://my-service.fastmcp.app/mcp", text: $mcpEndpointURL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .monospaced()
                        .font(.callout)
                } header: {
                    Text("MCP Endpoint URL")
                } footer: {
                    if urlChanged {
                        Label("URL changed — operator will need to re-register with its Authority", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Text("The operator's public MCP endpoint.")
                    }
                }

                Section {
                    HStack {
                        if showNsec {
                            TextField("nsec1...", text: $nsec)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .monospaced()
                                .font(.callout)
                        } else {
                            SecureField("nsec1...", text: $nsec)
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
                    Text("Secret Key (nsec)")
                } footer: {
                    Text("Stored securely in the device Keychain. Leave blank to keep the existing key.")
                }
            }
            .navigationTitle("Edit Operator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
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
                        let trimmedURL = mcpEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        if urlChanged {
                            operator_.mcpEndpointURL = trimmedURL.isEmpty ? nil : trimmedURL
                            // URL changed — operator must re-register
                            operator_.authorityNpub = nil
                            try? modelContext.save()
                        }
                        let trimmedNsec = nsec.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedNsec.isEmpty {
                            try? KeychainService.saveNsec(trimmedNsec, forNpub: operator_.npub)
                        }
                        dismiss()
                    }
                    .disabled(!hasChanges)
                }
            }
            .task {
                hasStoredNsec = KeychainService.loadNsec(forNpub: operator_.npub) != nil
            }
        }
    }
}
