import SwiftUI

struct EditPatronSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    var viewModel: PatronCollectionViewModel
    let patron: Patron

    // Local identity fields
    @State private var displayName: String
    @State private var nip05: String
    @State private var nsec: String = ""
    @State private var showNsec = false
    @State private var hasStoredNsec = false
    @State private var keyError: String?

    // Nostr kind-0 public-profile fields (folded in from the old standalone sheet)
    @State private var about = ""
    @State private var picture: String
    @State private var website = ""
    @State private var lud16 = ""
    @State private var showAvatarPicker = false
    @State private var profileLoading = true

    // Baselines so Save only enables when something actually changed.
    @State private var baseAbout = ""
    @State private var baseWebsite = ""
    @State private var baseLud16 = ""

    private let profileService = NostrProfileService()

    init(viewModel: PatronCollectionViewModel, patron: Patron) {
        self.viewModel = viewModel
        self.patron = patron
        self._displayName = State(initialValue: patron.displayName)
        self._nip05 = State(initialValue: patron.nip05 ?? "")
        self._picture = State(initialValue: patron.pictureURL ?? "")
    }

    private var hasChanges: Bool {
        let nameChanged = !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && displayName != patron.displayName
        let nip05Changed = nip05.trimmingCharacters(in: .whitespacesAndNewlines) != (patron.nip05 ?? "")
        let nsecChanged = !nsec.isEmpty && keyError == nil
        let pictureChanged = picture.trimmingCharacters(in: .whitespacesAndNewlines) != (patron.pictureURL ?? "")
        let profileChanged = about != baseAbout || website != baseWebsite || lud16 != baseLud16
        return nameChanged || nip05Changed || nsecChanged || pictureChanged || profileChanged
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
                    DisclosureGroup(isExpanded: $showAvatarPicker) {
                        AvatarPickerView(selectedURL: $picture)
                    } label: {
                        HStack {
                            Text("Avatar")
                            Spacer()
                            AvatarView(value: picture, size: 30)
                        }
                    }
                } header: {
                    Text("Avatar")
                } footer: {
                    Text("Public picture for your Nostr profile. Shows everywhere this patron appears.")
                }

                Section {
                    TextField("About", text: $about, axis: .vertical).lineLimit(3 ... 6)
                } header: {
                    Text("About")
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
                    Text("Optional. Nostr-verifiable name (e.g. prime-curator@tollbooth-dpyc.org).")
                }

                Section {
                    TextField("https://example.com", text: $website)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.callout)
                } header: {
                    Text("Website")
                }

                Section {
                    TextField("you@wallet.com", text: $lud16)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .font(.callout)
                } header: {
                    Text("Lightning Address")
                } footer: {
                    Text("Optional. A Lightning (LNURL-pay) address for receiving sats.")
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
                    } else if !hasStoredNsec {
                        Label("No signing key — profile changes save locally but won't publish to Nostr.",
                              systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                    Button("Save") { save() }
                        .disabled(!hasChanges)
                }
            }
            .task {
                hasStoredNsec = KeychainService.loadNsec(forNpub: patron.npub) != nil
                await loadProfile()
            }
            .onChange(of: nsec) { _, newValue in
                validateNsec(newValue)
            }
        }
    }

    /// Read the current kind-0 from relays to prefill the public-profile fields.
    /// The cached `pictureURL` is shown immediately; relay values fill in the
    /// rest (and refresh the avatar) when they arrive.
    private func loadProfile() async {
        profileLoading = true
        if let m = await profileService.fetch(npub: patron.npub) {
            about = m.about ?? ""
            website = m.website ?? ""
            lud16 = m.lud16 ?? ""
            if let p = m.picture, !p.isEmpty { picture = p }
            if displayName.isEmpty { displayName = m.display_name ?? m.name ?? "" }
        }
        baseAbout = about
        baseWebsite = website
        baseLud16 = lud16
        profileLoading = false
    }

    /// One Save: persist the local Patron synchronously, dismiss immediately, and
    /// publish the kind-0 profile to relays in the background (best-effort, only
    /// when a signing key is held). The user does not wait on the relay round-trip.
    private func save() {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNip05 = nip05.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNsec = nsec.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPicture = picture.trimmingCharacters(in: .whitespacesAndNewlines)

        viewModel.updatePatron(
            patron,
            displayName: trimmedName,
            nsec: trimmedNsec.isEmpty ? nil : trimmedNsec,
            nip05: trimmedNip05.isEmpty ? nil : trimmedNip05,
            pictureURL: trimmedPicture.isEmpty ? nil : trimmedPicture,
            context: modelContext
        )

        // Capture the (possibly nsec-derived) npub AFTER the local save.
        let npub = patron.npub
        if KeychainService.loadNsec(forNpub: npub) != nil {
            let meta = NostrProfileMetadata(
                name: trimmedName, display_name: trimmedName, about: about,
                picture: trimmedPicture, nip05: trimmedNip05, website: website, lud16: lud16
            )
            Task.detached(priority: .utility) {
                _ = try? await NostrProfileService().publish(npub: npub, metadata: meta)
            }
        }

        dismiss()
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
