import SwiftUI

struct AssistantAPIKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey: String = ""
    @State private var xaiKey: String = ""
    @State private var isSaved = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("sk-ant-...", text: $apiKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Anthropic API Key")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Used for the Pricing Consultant interview (Claude).")
                        Link("Get an API key at console.anthropic.com",
                             destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    }
                }

                Section {
                    SecureField("xai-...", text: $xaiKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("xAI API Key")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Used for the Second Opinion reviewer (Grok). If not set, Claude is used as fallback.")
                        Link("Get an API key at console.x.ai",
                             destination: URL(string: "https://console.x.ai/")!)
                    }
                }

                if isSaved {
                    Section {
                        Label("API keys saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        KeychainService.deleteAnthropicAPIKey()
                        apiKey = ""
                        isSaved = false
                    } label: {
                        Label("Remove Anthropic Key", systemImage: "trash")
                    }
                    .disabled(KeychainService.loadAnthropicAPIKey() == nil && apiKey.isEmpty)

                    Button(role: .destructive) {
                        KeychainService.deleteXAIAPIKey()
                        xaiKey = ""
                        isSaved = false
                    } label: {
                        Label("Remove xAI Key", systemImage: "trash")
                    }
                    .disabled(KeychainService.loadXAIAPIKey() == nil && xaiKey.isEmpty)
                }
            }
            .navigationTitle("AI Assistant Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmedAnthropic = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedXAI = xaiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedAnthropic.isEmpty {
                            try? KeychainService.saveAnthropicAPIKey(trimmedAnthropic)
                        }
                        if !trimmedXAI.isEmpty {
                            try? KeychainService.saveXAIAPIKey(trimmedXAI)
                        }
                        isSaved = true
                    }
                    .disabled(
                        apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && xaiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
            .onAppear {
                if let existing = KeychainService.loadAnthropicAPIKey() {
                    apiKey = existing
                }
                if let existing = KeychainService.loadXAIAPIKey() {
                    xaiKey = existing
                }
            }
        }
    }
}
