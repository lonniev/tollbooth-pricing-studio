import SwiftUI
import PricingStudioCore

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

    // API Key
    @State private var openRouterKey: String = ""
    @State private var keySaveStatus: String?
    @State private var pollInterval: Double = DMPollingService.shared.pollIntervalSeconds
    @State private var notificationMode: DMPollingService.NotificationMode = DMPollingService.shared.notificationMode

    // Per-role model slugs (not secret — UserDefaults)
    @State private var owlSlug: String = ModelRoleSettings.slug(for: .owl)
    @State private var advisorSlug: String = ModelRoleSettings.slug(for: .advisor)
    @State private var adversarySlug: String = ModelRoleSettings.slug(for: .adversary)
    @State private var modelsSaveStatus: String?

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

                // MARK: - OpenRouter API Key

                Section {
                    SecureField("sk-or-...", text: $openRouterKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Label("OpenRouter API Key", systemImage: "key.fill")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Powers Owl, the Pricing Consultant advisors, and the adversarial second opinion through one key.")
                        Link("Get a key at openrouter.ai/keys",
                             destination: URL(string: "https://openrouter.ai/keys")!)
                    }
                }

                if let status = keySaveStatus {
                    Section {
                        Label(status, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                Section {
                    Button("Save API Key") {
                        saveAPIKey()
                    }
                    .disabled(openRouterKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button(role: .destructive) {
                        KeychainService.deleteOpenRouterAPIKey()
                        openRouterKey = ""
                        keySaveStatus = nil
                    } label: {
                        Label("Remove OpenRouter Key", systemImage: "trash")
                    }
                    .disabled(
                        KeychainService.loadOpenRouterAPIKey() == nil
                        && openRouterKey.isEmpty
                    )
                }

                // MARK: - Models

                Section {
                    modelRow(role: .owl, slug: $owlSlug)
                    modelRow(role: .advisor, slug: $advisorSlug)
                    modelRow(role: .adversary, slug: $adversarySlug)

                    Button("Save Models") {
                        ModelRoleSettings.setSlug(owlSlug, for: .owl)
                        ModelRoleSettings.setSlug(advisorSlug, for: .advisor)
                        ModelRoleSettings.setSlug(adversarySlug, for: .adversary)
                        // Reload trimmed values (empty → default)
                        owlSlug = ModelRoleSettings.slug(for: .owl)
                        advisorSlug = ModelRoleSettings.slug(for: .advisor)
                        adversarySlug = ModelRoleSettings.slug(for: .adversary)
                        modelsSaveStatus = "Models saved"
                    }
                } header: {
                    Label("Models", systemImage: "brain")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("OpenRouter slugs chosen per role. Changing a slug affects the next reply only — earlier answers keep the model that produced them.")
                        if let status = modelsSaveStatus {
                            Text(status).foregroundStyle(.green)
                        }
                    }
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
                if let existing = KeychainService.loadOpenRouterAPIKey() {
                    openRouterKey = existing
                }
                owlSlug = ModelRoleSettings.slug(for: .owl)
                advisorSlug = ModelRoleSettings.slug(for: .advisor)
                adversarySlug = ModelRoleSettings.slug(for: .adversary)
            }
        }
    }

    @ViewBuilder
    private func modelRow(role: ModelRole, slug: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(role.displayLabel(slug: slug.wrappedValue.isEmpty ? role.defaultSlug : slug.wrappedValue))
                .font(.subheadline.weight(.semibold))
            TextField(role.defaultSlug, text: slug)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(role.suggestedSlugs, id: \.self) { suggestion in
                        Button(suggestion) {
                            slug.wrappedValue = suggestion
                        }
                        .font(.caption2.monospaced())
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ToolbarContentBuilder
    private func settingsToolbar() -> some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
        }
    }

    private func saveAPIKey() {
        let trimmed = openRouterKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            keySaveStatus = nil
            return
        }
        try? KeychainService.saveOpenRouterAPIKey(trimmed)
        keySaveStatus = "OpenRouter key saved"
    }
}
