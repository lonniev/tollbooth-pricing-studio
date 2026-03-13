import SwiftUI

struct AddOperatorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    var viewModel: OperatorCollectionViewModel

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
                    Text("Operator npub")
                } footer: {
                    Text("The Nostr public key of the MCP operator.")
                }

                Section {
                    TextField("Display Name", text: $displayName)
                } header: {
                    Text("Display Name")
                } footer: {
                    Text("A friendly name for this operator.")
                }
            }
            .navigationTitle("Add Operator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        viewModel.addOperator(
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
