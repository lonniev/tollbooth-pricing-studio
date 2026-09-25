import SwiftUI
import PricingStudioCore

struct AssistantAPIKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey: String = ""
    @State private var isSaved = false

    // Per-role model slugs
    @State private var owlSlug: String = ModelRoleSettings.slug(for: .owl)
    @State private var advisorSlug: String = ModelRoleSettings.slug(for: .advisor)
    @State private var adversarySlug: String = ModelRoleSettings.slug(for: .adversary)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("sk-or-...", text: $apiKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("OpenRouter API Key")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("One key for Owl, advisors, and the adversarial second opinion.")
                        Link("Get an API key at openrouter.ai/keys",
                             destination: URL(string: "https://openrouter.ai/keys")!)
                    }
                }

                Section {
                    modelField(title: ModelRole.owl.displayLabel(slug: owlSlug), slug: $owlSlug, role: .owl)
                    modelField(title: ModelRole.advisor.displayLabel(slug: advisorSlug), slug: $advisorSlug, role: .advisor)
                    modelField(title: ModelRole.adversary.displayLabel(slug: adversarySlug), slug: $adversarySlug, role: .adversary)
                } header: {
                    Text("Models")
                } footer: {
                    Text("OpenRouter slugs chosen per role. Earlier answers keep the slug that produced them.")
                }

                if isSaved {
                    Section {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        KeychainService.deleteOpenRouterAPIKey()
                        apiKey = ""
                        isSaved = false
                    } label: {
                        Label("Remove OpenRouter Key", systemImage: "trash")
                    }
                    .disabled(KeychainService.loadOpenRouterAPIKey() == nil && apiKey.isEmpty)
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
                        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            try? KeychainService.saveOpenRouterAPIKey(trimmed)
                        }
                        ModelRoleSettings.setSlug(owlSlug, for: .owl)
                        ModelRoleSettings.setSlug(advisorSlug, for: .advisor)
                        ModelRoleSettings.setSlug(adversarySlug, for: .adversary)
                        owlSlug = ModelRoleSettings.slug(for: .owl)
                        advisorSlug = ModelRoleSettings.slug(for: .advisor)
                        adversarySlug = ModelRoleSettings.slug(for: .adversary)
                        isSaved = true
                    }
                }
            }
            .onAppear {
                if let existing = KeychainService.loadOpenRouterAPIKey() {
                    apiKey = existing
                }
                owlSlug = ModelRoleSettings.slug(for: .owl)
                advisorSlug = ModelRoleSettings.slug(for: .advisor)
                adversarySlug = ModelRoleSettings.slug(for: .adversary)
            }
        }
    }

    @ViewBuilder
    private func modelField(title: String, slug: Binding<String>, role: ModelRole) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(role.defaultSlug, text: slug)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
        }
    }
}
