import SwiftUI

struct AddConstraintSheet: View {
    let onAdd: (String, [String: AnyCodableValue]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedType: PipelineStepType?
    @State private var showingParamEditor = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(ConstraintCatalog.categories, id: \.self) { category in
                    Section(category) {
                        ForEach(ConstraintCatalog.specs(in: category), id: \.type) { spec in
                            Button {
                                selectedType = spec.type
                                showingParamEditor = true
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(spec.type.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                                        .font(.headline)
                                    Text(spec.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Constraint")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showingParamEditor) {
                if let type = selectedType {
                    ConstraintParamEditor(
                        spec: ConstraintCatalog.spec(for: type)!,
                        existingParams: nil,
                        onSave: { params in
                            onAdd(type.rawValue, params)
                            dismiss()
                        }
                    )
                }
            }
        }
    }
}
