import DPYCAuthKit
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
    /// Set when the user flips the notification mute toggle so Save enables,
    /// even though the preference itself already persisted immediately.
    @State private var notifPrefChanged = false

    // Nostr kind-0 public-profile fields (folded in from the old standalone sheet)
    @State private var about = ""
    @State private var picture: String
    @State private var website = ""
    @State private var lud16 = ""
    @State private var showAvatarPicker = false
    @State private var profileLoading = true
    @State private var saving = false
    /// Why the last Save reached no relay; the local copy is saved either way.
    @State private var publishProblem: String?

    // Baselines so Save only enables when something actually changed.
    @State private var baseAbout = ""
    @State private var baseWebsite = ""
    @State private var baseLud16 = ""
    @State private var baseNip05: String

    private let profileService = NostrProfileService()

    init(viewModel: PatronCollectionViewModel, patron: Patron) {
        self.viewModel = viewModel
        self.patron = patron
        self._displayName = State(initialValue: patron.displayName)
        self._nip05 = State(initialValue: patron.nip05 ?? "")
        self._picture = State(initialValue: patron.pictureURL ?? "")
        self._baseNip05 = State(initialValue: patron.nip05 ?? "")
    }

    private var hasChanges: Bool {
        let nameChanged = !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && displayName != patron.displayName
        let nip05Changed = nip05.trimmingCharacters(in: .whitespacesAndNewlines) != baseNip05
        let nsecChanged = !nsec.isEmpty && keyError == nil
        let pictureChanged = picture.trimmingCharacters(in: .whitespacesAndNewlines) != (patron.pictureURL ?? "")
        let profileChanged = about != baseAbout || website != baseWebsite || lud16 != baseLud16
        return nameChanged || nip05Changed || nsecChanged || pictureChanged || profileChanged || notifPrefChanged
    }

    var body: some View {
        NavigationStack {
            Form {
                if let problem = publishProblem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
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

                NotificationToggleSection(npub: patron.npub) { notifPrefChanged = true }
                if hasStoredNsec {
                    NostrConnectSection(npub: patron.npub)
                }
            }
            .navigationTitle("Edit Patron")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .disabled(!hasChanges && publishProblem == nil)
                    }
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
    /// The cached `pictureURL` and `nip05` show at once. Relay values arrive
    /// seconds later and fill only fields still as the sheet opened them, so a
    /// slow relay never overwrites what was typed meanwhile. A NIP-05 kept only
    /// on the relays is filled in, so Save never publishes a profile without it.
    private func loadProfile() async {
        profileLoading = true
        let opened = (about: about, website: website, lud16: lud16, picture: picture, nip05: nip05)
        if let m = await profileService.fetch(npub: patron.npub) {
            about = ProfileFill.fill(about, opened: opened.about, relay: m.about)
            website = ProfileFill.fill(website, opened: opened.website, relay: m.website)
            lud16 = ProfileFill.fill(lud16, opened: opened.lud16, relay: m.lud16)
            picture = ProfileFill.fill(picture, opened: opened.picture, relay: m.picture, keepWhenRelayEmpty: true)
            if opened.nip05.isEmpty {
                let filled = ProfileFill.fill(nip05, opened: "", relay: m.nip05)
                if filled != nip05 {
                    nip05 = filled
                    baseNip05 = filled
                }
            }
            if displayName.isEmpty { displayName = m.display_name ?? m.name ?? "" }
            baseAbout = m.about ?? ""
            baseWebsite = m.website ?? ""
            baseLud16 = m.lud16 ?? ""
        }
        profileLoading = false
    }

    /// One Save: persist the local Patron, then publish the kind-0 profile to
    /// relays when a signing key is held, and close only once a relay accepted
    /// it. When none did, the sheet stays open and says why, and Save tries again.
    /// Website, about and Lightning address live only in the published profile.
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

        baseNip05 = trimmedNip05

        // Capture the (possibly nsec-derived) npub AFTER the local save.
        let npub = patron.npub
        guard KeychainService.loadNsec(forNpub: npub) != nil else {
            dismiss()
            return
        }
        let meta = NostrProfileMetadata(
            name: trimmedName, display_name: trimmedName, about: about,
            picture: trimmedPicture, nip05: trimmedNip05, website: website, lud16: lud16
        )
        saving = true
        publishProblem = nil
        Task {
            do {
                let results = try await NostrProfileService().publish(npub: npub, metadata: meta)
                if let problem = ProfileFill.problem(results) {
                    publishProblem = problem
                } else {
                    dismiss()
                }
            } catch {
                publishProblem = error.localizedDescription
            }
            saving = false
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

/// Pure rules for the Edit Patron sheet's profile fields.
enum ProfileFill {
    /// A field's value once the relays' profile arrives: the relay's value while
    /// the field still holds what the sheet opened with, else what was typed.
    /// `keepWhenRelayEmpty` keeps the opened value when the relay has none.
    static func fill(_ current: String, opened: String, relay: String?, keepWhenRelayEmpty: Bool = false) -> String {
        guard current == opened else { return current }
        let value = relay?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty && keepWhenRelayEmpty ? current : value
    }

    /// Why a publish reached no relay, or nil when at least one accepted it.
    static func problem(_ results: [(URL, Bool, String)]) -> String? {
        if results.contains(where: { $0.1 }) { return nil }
        guard let first = results.first else {
            return "No relays are set up, so the profile is saved on this device only. Add a relay in Settings, then Save again."
        }
        let why = first.2.isEmpty ? "" : " (\(first.0.host ?? first.0.absoluteString): \(first.2))"
        return "No relay accepted the profile\(why). It is saved on this device; Save again to retry."
    }
}
