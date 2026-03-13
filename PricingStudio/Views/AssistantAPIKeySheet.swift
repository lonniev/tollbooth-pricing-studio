import SwiftUI

struct AssistantAPIKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey: String = ""
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
                        Text("Your API key is stored securely in the device Keychain. It is never sent anywhere except api.anthropic.com.")
                        Link("Get an API key at console.anthropic.com",
                             destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    }
                }

                if isSaved {
                    Section {
                        Label("API key saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        KeychainService.deleteAnthropicAPIKey()
                        apiKey = ""
                        isSaved = false
                    } label: {
                        Label("Remove API Key", systemImage: "trash")
                    }
                    .disabled(KeychainService.loadAnthropicAPIKey() == nil && apiKey.isEmpty)
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
                        try? KeychainService.saveAnthropicAPIKey(apiKey)
                        isSaved = true
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if let existing = KeychainService.loadAnthropicAPIKey() {
                    apiKey = existing
                }
            }
        }
    }
}
