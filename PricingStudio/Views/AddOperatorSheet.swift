import SwiftUI

struct AddOperatorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    var viewModel: OperatorCollectionViewModel

    @State private var npub = ""
    @State private var nsec = ""
    @State private var displayName = ""
    @State private var derivedNpub: String?
    @State private var keyError: String?

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
                    SecureField("nsec1... (optional)", text: $nsec)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .monospaced()
                        .font(.callout)
                        .onChange(of: nsec) { _, newValue in
                            deriveNpubFromNsec(newValue)
                        }
                } header: {
                    Text("Operator nsec")
                } footer: {
                    if let error = keyError {
                        Text(error).foregroundStyle(.red)
                    } else if derivedNpub != nil {
                        Label("npub derived from nsec", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("Provide the nsec to act as this operator. The npub will be derived automatically.")
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

                        viewModel.addOperator(
                            npub: finalNpub,
                            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                            context: modelContext
                        )

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
