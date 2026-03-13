import SwiftUI

struct EditPatronSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    var viewModel: PatronCollectionViewModel
    let patron: Patron

    @State private var displayName: String
    @State private var nsec: String = ""
    @State private var showNsec = false
    @State private var hasStoredNsec = false
    @State private var keyError: String?

    init(viewModel: PatronCollectionViewModel, patron: Patron) {
        self.viewModel = viewModel
        self.patron = patron
        self._displayName = State(initialValue: patron.displayName)
    }

    private var hasChanges: Bool {
        let nameChanged = !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && displayName != patron.displayName
        let nsecChanged = !nsec.isEmpty && keyError == nil
        return nameChanged || nsecChanged
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(patron.npub)
                        .font(.callout)
                        .monospaced()
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Derived npub")
                } footer: {
                    Text("Derived from the stored nsec. Read-only.")
                }

                Section {
                    TextField("Display Name", text: $displayName)
                } header: {
                    Text("Display Name")
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
                    if let error = keyError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Secret Key (nsec)")
                } footer: {
                    Text("Leave blank to keep the existing key. Changing the nsec will update the derived npub.")
                }
            }
            .navigationTitle("Edit Patron")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedNsec = nsec.trimmingCharacters(in: .whitespacesAndNewlines)
                        viewModel.updatePatron(
                            patron,
                            displayName: trimmedName,
                            nsec: trimmedNsec.isEmpty ? nil : trimmedNsec,
                            context: modelContext
                        )
                        dismiss()
                    }
                    .disabled(!hasChanges)
                }
            }
            .task {
                hasStoredNsec = KeychainService.loadNsec(forNpub: patron.npub) != nil
            }
            .onChange(of: nsec) { _, newValue in
                validateNsec(newValue)
            }
        }
    }

    private func validateNsec(_ nsec: String) {
        let trimmed = nsec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            keyError = nil
            return
        }
        do {
            _ = try NostrKeyService.npubFromNsec(trimmed)
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
    }
}
