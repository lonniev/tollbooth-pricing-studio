import SwiftUI

struct AddAuthoritySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    var viewModel: AuthorityCollectionViewModel

    @State private var npub = ""
    @State private var displayName = ""

    private var isValid: Bool {
        npub.hasPrefix("npub1") && npub.count > 10 && !displayName.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("npub1...", text: $npub)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .monospaced()
                        .font(.callout)
                } header: {
                    Text("Authority npub")
                } footer: {
                    Text("The Nostr public key of the Authority.")
                }

                Section {
                    TextField("Display Name", text: $displayName)
                } header: {
                    Text("Display Name")
                } footer: {
                    Text("A friendly name for this authority.")
                }
            }
            .navigationTitle("Add Authority")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        viewModel.addAuthority(
                            npub: npub.trimmingCharacters(in: .whitespacesAndNewlines),
                            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                            context: modelContext
                        )
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }
}
