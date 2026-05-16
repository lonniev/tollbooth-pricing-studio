import SwiftUI
import SwiftData
import UIKit

/// Pre-fill payload for adopting an Authority already published in the
/// dpyc-community registry. When passed to ``AddAuthoritySheet``, the form
/// locks the npub field, hides the "generate keys" affordance, and seeds
/// display name / endpoint / parent from the registry entry.
struct AdoptionPrefill: Identifiable, Equatable {
    let npub: String
    let displayName: String
    let mcpEndpointURL: String?
    let upstreamAuthorityNpub: String?
    let role: String

    var id: String { npub }
    var isPrime: Bool { role == "prime_authority" }
}

struct AddAuthoritySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    var viewModel: AuthorityCollectionViewModel
    let prefill: AdoptionPrefill?

    @State private var npub: String
    @State private var nsec = ""
    @State private var displayName: String
    @State private var nip05 = ""
    @State private var derivedNpub: String?
    @State private var keyError: String?
    @State private var generatedKeys = false
    @State private var copiedNsec = false

    init(viewModel: AuthorityCollectionViewModel, prefill: AdoptionPrefill? = nil) {
        self.viewModel = viewModel
        self.prefill = prefill
        _npub = State(initialValue: prefill?.npub ?? "")
        _displayName = State(initialValue: prefill?.displayName ?? "")
    }

    private var isAdoption: Bool { prefill != nil }

    private var effectiveNpub: String {
        derivedNpub ?? npub
    }

    private var isValid: Bool {
        effectiveNpub.hasPrefix("npub1") && effectiveNpub.count > 10 && !displayName.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if let prefill {
                    adoptionBanner(prefill)
                }

                if !isAdoption {
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
                            Text("Create a brand-new Nostr identity for this authority.")
                        }
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
                                if !generatedKeys && !isAdoption {
                                    deriveNpubFromNsec(newValue)
                                } else if isAdoption {
                                    validateNsecAgainstPrefill(newValue)
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
                    Text(isAdoption ? "Authority nsec (optional)" : "Authority nsec")
                } footer: {
                    if let error = keyError {
                        Text(error).foregroundStyle(.red)
                    } else if copiedNsec {
                        Label("Copied to clipboard — save this nsec in your vault now", systemImage: "exclamationmark.shield.fill")
                            .foregroundStyle(.orange)
                    } else if generatedKeys {
                        Label("npub derived from nsec — copy and save before dismissing", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else if isAdoption {
                        Text("Optional — paste the nsec now to sign DMs as this Authority, or add it later from the Authority's claim flow.")
                    } else if derivedNpub != nil {
                        Label("npub derived from nsec", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("Provide the nsec to act as this authority, or generate keys above.")
                    }
                }

                Section {
                    TextField("npub1...", text: $npub)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .monospaced()
                        .font(.callout)
                        .disabled(derivedNpub != nil || isAdoption)
                        .foregroundStyle((derivedNpub != nil || isAdoption) ? .secondary : .primary)
                } header: {
                    Text("Authority npub")
                } footer: {
                    if isAdoption {
                        Text("Locked — sourced from the dpyc-community registry.")
                    } else if let derived = derivedNpub {
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
                    if isAdoption {
                        Text("Seeded from the registry. Edit to override the name shown locally.")
                    } else {
                        Text("A friendly name for this authority.")
                    }
                }

                if !isAdoption {
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
                }

                if let prefill, let url = prefill.mcpEndpointURL, !url.isEmpty {
                    Section {
                        Text(url)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } header: {
                        Text("MCP Endpoint")
                    } footer: {
                        Text("Wired from the registry — will be set on adoption.")
                    }
                }
            }
            .navigationTitle(isAdoption ? "Adopt Authority" : "Add Authority")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isAdoption ? "Adopt" : "Add") {
                        commit()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }

    private func adoptionBanner(_ prefill: AdoptionPrefill) -> some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: prefill.isPrime ? "crown.fill" : "building.columns.fill")
                    .foregroundStyle(.indigo)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Adopting from dpyc-community")
                        .font(.subheadline.weight(.semibold))
                    Text(prefill.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let upstream = prefill.upstreamAuthorityNpub {
                        Text("Parent: \(upstream.prefix(20))…")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func commit() {
        let finalNpub = effectiveNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNsec = nsec.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDisplay = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNip05 = nip05.trimmingCharacters(in: .whitespacesAndNewlines)

        if let prefill {
            viewModel.ensureAuthority(
                npub: finalNpub,
                displayName: trimmedDisplay,
                endpointURL: prefill.mcpEndpointURL,
                context: modelContext
            )
            // ensureAuthority creates with displayName from registry; override
            // with the user's possibly-edited value, and stamp the upstream
            // pointer so the topology re-renders the parent edge immediately.
            let descriptor = FetchDescriptor<Authority>(predicate: #Predicate { $0.npub == finalNpub })
            if let auth = try? modelContext.fetch(descriptor).first {
                if auth.displayName != trimmedDisplay {
                    auth.displayName = trimmedDisplay
                }
                if let upstream = prefill.upstreamAuthorityNpub, auth.parentAuthorityNpub != upstream {
                    auth.parentAuthorityNpub = upstream
                }
                try? modelContext.save()
            }
        } else {
            viewModel.addAuthority(
                npub: finalNpub,
                displayName: trimmedDisplay,
                context: modelContext
            )
            if !trimmedNip05.isEmpty {
                viewModel.selectedAuthority?.nip05 = trimmedNip05
                try? modelContext.save()
            }
        }

        if !trimmedNsec.isEmpty {
            try? KeychainService.saveNsec(trimmedNsec, forNpub: finalNpub)
        }

        dismiss()
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

    /// In adoption mode, if the user pastes a nsec, confirm it actually
    /// derives to the npub the registry told us about — catches paste-mix-ups
    /// before they write the wrong nsec to Keychain under this npub.
    private func validateNsecAgainstPrefill(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            keyError = nil
            return
        }
        guard trimmed.hasPrefix("nsec1") else {
            keyError = "Must start with nsec1"
            return
        }
        do {
            let derived = try NostrKeyService.npubFromNsec(trimmed)
            if derived != prefill?.npub {
                keyError = "This nsec derives to a different npub than the registry entry."
            } else {
                keyError = nil
            }
        } catch {
            keyError = error.localizedDescription
        }
    }
}
