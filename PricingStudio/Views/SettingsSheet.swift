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

    // API Keys
    @State private var anthropicKey: String = ""
    @State private var xaiKey: String = ""
    @State private var keySaveStatus: String?
    @State private var pollInterval: Double = DMPollingService.shared.pollIntervalSeconds
    @State private var notificationMode: DMPollingService.NotificationMode = DMPollingService.shared.notificationMode

    private var relayFooter: String {
        let base = "Supported relays are governed by the DPYC community registry "
            + "and refresh automatically."
        guard let fetchedAt = relaySettings.fetchedAt else { return base }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .full
        return base + " Last updated \(fmt.localizedString(for: fetchedAt, relativeTo: Date()))."
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - About

                Section {
                    LabeledContent("App", value: Bundle.main.appName)
                    LabeledContent("Version", value: Bundle.main.appVersion)
                    LabeledContent("Build", value: Bundle.main.buildTimestamp)
                    LabeledContent("Patent", value: "Pending — US 64/045,999")
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
                    if relaySettings.relays.isEmpty {
                        Text("Loading relays from the DPYC community registry…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(relaySettings.relays, id: \.self) { relay in
                            Text(relay)
                                .font(.callout)
                                .monospaced()
                        }
                    }

                    Button {
                        Task { await relaySettings.refresh(force: true) }
                    } label: {
                        Label("Refresh Relays", systemImage: "arrow.clockwise")
                    }
                } header: {
                    Label("Nostr Relays", systemImage: "antenna.radiowaves.left.and.right")
                } footer: {
                    Text(relayFooter)
                }

                // MARK: - Nostr Polling

                Section {
                    HStack {
                        Text("Poll Interval")
                        Spacer()
                        Text("\(Int(pollInterval))s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $pollInterval, in: 2...60, step: 1)
                        .onChange(of: pollInterval) {
                            DMPollingService.shared.pollIntervalSeconds = pollInterval
                        }
                } header: {
                    Label("Nostr Polling", systemImage: "timer")
                } footer: {
                    Text("How often to check relays for new messages. Lower = faster updates, more bandwidth.")
                }

                // MARK: - DM Notifications

                Section {
                    Picker("Notification Mode", selection: $notificationMode) {
                        ForEach(DMPollingService.NotificationMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .onChange(of: notificationMode) {
                        DMPollingService.shared.notificationMode = notificationMode
                    }
                } header: {
                    Label("DM Notifications", systemImage: "bell")
                } footer: {
                    Text(notificationMode.description)
                }

            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: settingsToolbar)
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

}
