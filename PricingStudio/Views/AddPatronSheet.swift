import SwiftUI
import UIKit

struct AddPatronSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    var viewModel: PatronCollectionViewModel

    @State private var displayName = ""
    @State private var nsec = ""
    @State private var showNsec = false
    @State private var derivedNpub: String?
    @State private var keyError: String?
    @State private var generatedKeys = false
    @State private var copiedNsec = false

    private var isValid: Bool {
        !displayName.isEmpty && derivedNpub != nil
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
                        Text("Create a brand-new Nostr identity for this patron.")
                    }
                }

                Section {
                    TextField("Display Name", text: $displayName)
                } header: {
                    Text("Display Name")
                } footer: {
                    Text("A friendly name for this patron.")
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
                    if let error = keyError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Secret Key (nsec)")
                } footer: {
                    if copiedNsec {
                        Label("Copied to clipboard — save this nsec in your vault now", systemImage: "exclamationmark.shield.fill")
                            .foregroundStyle(.orange)
                    } else if generatedKeys {
                        Label("Copy and save the nsec before dismissing", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Required. The npub will be derived automatically. Stored securely in the device Keychain.")
                    }
                }

                if let npub = derivedNpub {
                    Section {
                        Text(npub)
                            .font(.callout)
                            .monospaced()
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Derived npub")
                    }
                }
            }
            .navigationTitle("Add Patron")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let npub = derivedNpub else { return }
                        viewModel.addPatron(
                            npub: npub,
                            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                            nsec: nsec.trimmingCharacters(in: .whitespacesAndNewlines),
                            context: modelContext
                        )
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
            .onChange(of: nsec) { _, newValue in
                if !generatedKeys {
                    deriveNpub(from: newValue)
                }
            }
        }
    }

    private func generateNewKeys() {
        do {
            let keys = try NostrKeyService.generateKeyPair()
            nsec = keys.nsec
            derivedNpub = keys.npub
            keyError = nil
            generatedKeys = true
        } catch {
            keyError = "Key generation failed: \(error.localizedDescription)"
        }
    }

    private func deriveNpub(from nsec: String) {
        let trimmed = nsec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            derivedNpub = nil
            keyError = nil
            return
        }
        do {
            derivedNpub = try NostrKeyService.npubFromNsec(trimmed)
            keyError = nil
        } catch {
            derivedNpub = nil
            keyError = error.localizedDescription
        }
    }
}
