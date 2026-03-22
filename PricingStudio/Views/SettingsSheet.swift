import SwiftUI

extension Bundle {
    var appName: String { infoDictionary?["CFBundleName"] as? String ?? "–" }
    var appVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "–" }
    var buildNumber: String { infoDictionary?["CFBundleVersion"] as? String ?? "–" }
    var buildTimestamp: String {
        guard let url = self.url(forResource: "BuildTimestamp", withExtension: "txt"),
              let stamp = try? String(contentsOf: url).trimmingCharacters(in: .whitespacesAndNewlines)
        else { return "–" }
        return stamp
    }
}

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var relaySettings = RelaySettings.shared

    @State private var newRelayURL = ""
    @State private var showingValidationError = false

    // API Keys
    @State private var anthropicKey: String = ""
    @State private var xaiKey: String = ""
    @State private var keySaveStatus: String?

    private var isValidNewRelay: Bool {
        newRelayURL.hasPrefix("wss://") && newRelayURL.count > 6
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - About

                Section {
                    LabeledContent("App", value: Bundle.main.appName)
                    LabeledContent("Version", value: Bundle.main.appVersion)
                    LabeledContent("Build", value: Bundle.main.buildTimestamp)
                } header: {
                    Label("About", systemImage: "info.circle")
                }

                // MARK: - AI Agent Keys

                Section {
                    SecureField("sk-ant-...", text: $anthropicKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Label("Anthropic API Key", systemImage: "brain")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Powers the Pricing Consultant interview (Claude).")
                        Link("Get a key at console.anthropic.com",
                             destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    }
                }

                Section {
                    SecureField("xai-...", text: $xaiKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Label("xAI API Key", systemImage: "sparkles")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Powers the Second Opinion reviewer (Grok). Falls back to Claude if not set.")
                        Link("Get a key at console.x.ai",
                             destination: URL(string: "https://console.x.ai/")!)
                    }
                }

                if let status = keySaveStatus {
                    Section {
                        Label(status, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                Section {
                    Button("Save API Keys") {
                        saveAPIKeys()
                    }
                    .disabled(
                        anthropicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && xaiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )

                    Button(role: .destructive) {
                        KeychainService.deleteAnthropicAPIKey()
                        KeychainService.deleteXAIAPIKey()
                        anthropicKey = ""
                        xaiKey = ""
                        keySaveStatus = nil
                    } label: {
                        Label("Remove All API Keys", systemImage: "trash")
                    }
                    .disabled(
                        KeychainService.loadAnthropicAPIKey() == nil
                        && KeychainService.loadXAIAPIKey() == nil
                        && anthropicKey.isEmpty
                        && xaiKey.isEmpty
                    )
                }

                // MARK: - Nostr Relays

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
                    Label("Nostr Relays", systemImage: "antenna.radiowaves.left.and.right")
                } footer: {
                    Text("WebSocket relay URLs for Nostr communication. Must begin with wss://.")
                }

                Section {
                    Button("Reset Relays to Defaults") {
                        withAnimation {
                            relaySettings.resetToDefaults()
                        }
                    }
                }

                // MARK: - Nostr Polling

                Section {
                    HStack {
                        Text("Poll Interval")
                        Spacer()
                        Text("\(Int(DMPollingService.shared.pollIntervalSeconds))s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { DMPollingService.shared.pollIntervalSeconds },
                            set: { DMPollingService.shared.pollIntervalSeconds = $0 }
                        ),
                        in: 2...60,
                        step: 1
                    )
                } header: {
                    Label("Nostr Polling", systemImage: "timer")
                } footer: {
                    Text("How often to check relays for new messages. Lower = faster updates, more bandwidth.")
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
            .onAppear {
                if let existing = KeychainService.loadAnthropicAPIKey() {
                    anthropicKey = existing
                }
                if let existing = KeychainService.loadXAIAPIKey() {
                    xaiKey = existing
                }
            }
        }
    }

    @ToolbarContentBuilder
    private func settingsToolbar() -> some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
        }
    }

    private func saveAPIKeys() {
        let trimmedAnthropic = anthropicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedXAI = xaiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var saved: [String] = []
        if !trimmedAnthropic.isEmpty {
            try? KeychainService.saveAnthropicAPIKey(trimmedAnthropic)
            saved.append("Anthropic")
        }
        if !trimmedXAI.isEmpty {
            try? KeychainService.saveXAIAPIKey(trimmedXAI)
            saved.append("xAI")
        }
        keySaveStatus = saved.isEmpty ? nil : "\(saved.joined(separator: " + ")) key\(saved.count > 1 ? "s" : "") saved"
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
