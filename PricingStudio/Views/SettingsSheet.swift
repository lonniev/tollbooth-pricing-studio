import SwiftUI

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var relaySettings = RelaySettings.shared

    @State private var newRelayURL = ""
    @State private var showingValidationError = false

    private var isValidNewRelay: Bool {
        newRelayURL.hasPrefix("wss://") && newRelayURL.count > 6
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(relaySettings.relays, id: \.self) { relay in
                        HStack {
                            Text(relay)
                                .font(.callout)
                                .monospaced()
                            Spacer()
                            Button(role: .destructive) {
                                withAnimation {
                                    relaySettings.relays.removeAll { $0 == relay }
                                }
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    HStack {
                        TextField("wss://relay.example.com", text: $newRelayURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .monospaced()
                            .font(.callout)
                            .onSubmit { addRelay() }

                        Button {
                            addRelay()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(!isValidNewRelay)
                        .buttonStyle(.borderless)
                    }
                } header: {
                    Text("Nostr Relays")
                } footer: {
                    Text("WebSocket relay URLs used for Nostr communication. URLs must begin with wss://.")
                }

                Section {
                    Button("Reset to Defaults") {
                        withAnimation {
                            relaySettings.resetToDefaults()
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: settingsToolbar)
            .alert("Invalid Relay URL", isPresented: $showingValidationError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Relay URLs must start with wss:// and contain a valid host.")
            }
        }
    }

    @ToolbarContentBuilder
    private func settingsToolbar() -> some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
        }
    }

    private func addRelay() {
        let trimmed = newRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("wss://"), trimmed.count > 6,
              URL(string: trimmed) != nil else {
            showingValidationError = true
            return
        }
        guard !relaySettings.relays.contains(trimmed) else {
            newRelayURL = ""
            return
        }
        withAnimation {
            relaySettings.relays.append(trimmed)
        }
        newRelayURL = ""
    }
}
