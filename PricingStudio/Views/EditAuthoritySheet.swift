import SwiftUI

struct EditAuthoritySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    var viewModel: AuthorityCollectionViewModel
    let authority: Authority

    @State private var displayName: String
    @State private var nip05: String
    @State private var nsec: String = ""
    @State private var showNsec = false
    @State private var hasStoredNsec = false

    init(viewModel: AuthorityCollectionViewModel, authority: Authority) {
        self.viewModel = viewModel
        self.authority = authority
        self._displayName = State(initialValue: authority.displayName)
        self._nip05 = State(initialValue: authority.nip05 ?? "")
    }

    private var hasChanges: Bool {
        let nameChanged = !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && displayName != authority.displayName
        let nip05Changed = nip05.trimmingCharacters(in: .whitespacesAndNewlines) != (authority.nip05 ?? "")
        let nsecChanged = !nsec.isEmpty
        return nameChanged || nip05Changed || nsecChanged
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(authority.npub)
                        .font(.callout)
                        .monospaced()
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Authority npub")
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
                    HStack {
                        if showNsec {
                            TextField("nsec1...", text: $nsec)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .monospaced()
                                .font(.callout)
                        } else {
                            SecureField("nsec1...", text: $nsec)
                                .textContentType(.password)
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

                if authority.isAutoDiscovered {
                    Section {
                        Label("Auto-discovered from operator lookup", systemImage: "sparkles")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                NotificationToggleSection(npub: authority.npub)
            }
            .navigationTitle("Edit Authority")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedNip05 = nip05.trimmingCharacters(in: .whitespacesAndNewlines)
                        authority.nip05 = trimmedNip05.isEmpty ? nil : trimmedNip05
                        if trimmedName != authority.displayName {
                            viewModel.updateAuthority(authority, displayName: trimmedName, context: modelContext)
                        }
                        let trimmedNsec = nsec.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedNsec.isEmpty {
                            try? KeychainService.saveNsec(trimmedNsec, forNpub: authority.npub)
                        }
                        dismiss()
                    }
                    .disabled(!hasChanges)
                }
            }
            .task {
                hasStoredNsec = KeychainService.loadNsec(forNpub: authority.npub) != nil
            }
        }
    }
}
