import SwiftUI
import UIKit

struct AddOperatorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    var viewModel: OperatorCollectionViewModel

    @State private var npub = ""
    @State private var nsec = ""
    @State private var displayName = ""
    @State private var nip05 = ""
    @State private var mcpEndpointURL = ""
    @State private var derivedNpub: String?
    @State private var keyError: String?
    @State private var generatedKeys = false
    @State private var copiedNsec = false

    private var effectiveNpub: String {
        derivedNpub ?? npub
    }

    private var isValid: Bool {
        effectiveNpub.hasPrefix("npub1") && effectiveNpub.count > 10 && !displayName.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        generateNewKeys()
                    } label: {
                        Label("Generate Nostr Keys", systemImage: "key.fill")
                    }
                    .accessibilityIdentifier("generateKeysButton")
                    .disabled(generatedKeys)
                } footer: {
                    if generatedKeys {
                        Label("Keys generated — nsec and npub filled in below", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("Create a brand-new Nostr identity for this operator.")
                    }
                }

                Section {
                    HStack {
                        SecureField("nsec1... (optional)", text: $nsec)
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
                } header: {
                    Text("Operator nsec")
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
                        Text("Provide the nsec to act as this operator, or generate keys above.")
                    }
                }

                Section {
                    TextField("npub1...", text: $npub)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .monospaced()
                        .font(.callout)
                        .disabled(derivedNpub != nil)
                        .foregroundStyle(derivedNpub != nil ? .secondary : .primary)
                } header: {
                    Text("Operator npub")
                } footer: {
                    if let derived = derivedNpub {
                        Text(derived)
                            .font(.caption2)
                            .monospaced()
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Or enter the npub directly if you don't have the nsec.")
                    }
                }

                Section {
                    TextField("Display Name", text: $displayName)
                        .textContentType(.username)
                } header: {
                    Text("Display Name")
                } footer: {
                    Text("A friendly name for this operator.")
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
                    Text("The operator's public MCP endpoint. Required for registration with an Authority.")
                }
            }
            .navigationTitle("Add Operator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let finalNpub = effectiveNpub.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedNsec = nsec.trimmingCharacters(in: .whitespacesAndNewlines)

                        let trimmedURL = mcpEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedNip05 = nip05.trimmingCharacters(in: .whitespacesAndNewlines)
                        viewModel.addOperator(
                            npub: finalNpub,
                            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                            mcpEndpointURL: trimmedURL.isEmpty ? nil : trimmedURL,
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
                    .disabled(!isValid)
                }
            }
        }
    }

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
}
