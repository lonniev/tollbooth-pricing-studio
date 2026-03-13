import SwiftUI

struct EditOperatorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    var viewModel: OperatorCollectionViewModel
    let operator_: Operator

    @State private var displayName: String

    init(viewModel: OperatorCollectionViewModel, operator_: Operator) {
        self.viewModel = viewModel
        self.operator_ = operator_
        self._displayName = State(initialValue: operator_.displayName)
    }

    private var isValid: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && displayName != operator_.displayName
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(operator_.npub)
                        .font(.callout)
                        .monospaced()
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Operator npub")
                } footer: {
                    Text("The npub cannot be changed.")
                }

                Section {
                    TextField("Display Name", text: $displayName)
                } header: {
                    Text("Display Name")
                }
            }
            .navigationTitle("Edit Operator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        viewModel.updateOperator(
                            operator_,
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
