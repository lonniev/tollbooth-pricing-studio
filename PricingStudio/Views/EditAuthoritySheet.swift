import SwiftUI

struct EditAuthoritySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    var viewModel: AuthorityCollectionViewModel
    let authority: Authority

    @State private var displayName: String

    init(viewModel: AuthorityCollectionViewModel, authority: Authority) {
        self.viewModel = viewModel
        self.authority = authority
        self._displayName = State(initialValue: authority.displayName)
    }

    private var hasChanges: Bool {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != authority.displayName
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(authority.npub)
                        .font(.callout)
                        .monospaced()
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Authority npub")
                } footer: {
                    Text("The npub cannot be changed.")
                }

                Section {
                    TextField("Display Name", text: $displayName)
                } header: {
                    Text("Display Name")
                }

                if authority.isAutoDiscovered {
                    Section {
                        Label("Auto-discovered from operator lookup", systemImage: "sparkles")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Edit Authority")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed != authority.displayName {
                            viewModel.updateAuthority(authority, displayName: trimmed, context: modelContext)
                        }
                        dismiss()
                    }
                    .disabled(!hasChanges)
                }
            }
        }
    }
}
