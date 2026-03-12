import SwiftUI
import SwiftData

struct OperatorSidebarView: View {
    @Query(sort: \Operator.addedAt) private var operators: [Operator]
    @Environment(\.modelContext) private var modelContext
    @Bindable var viewModel: OperatorCollectionViewModel

    var body: some View {
        List(selection: $viewModel.selectedOperator) {
            ForEach(operators) { op in
                OperatorRow(op: op)
                    .tag(op)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            viewModel.deleteOperator(op, context: modelContext)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .navigationTitle("Operators")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.showingAddSheet = true
                } label: {
                    Label("Add Operator", systemImage: "plus")
                }
            }
        }
        .overlay {
            if operators.isEmpty {
                ContentUnavailableView(
                    "No Operators",
                    systemImage: "person.2.slash",
                    description: Text("Tap + to add an operator by npub.")
                )
            }
        }
    }
}

private struct OperatorRow: View {
    let op: Operator

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(op.displayName)
                .font(.headline)
            Text(truncatedNpub(op.npub))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospaced()
        }
        .padding(.vertical, 2)
    }

    private func truncatedNpub(_ npub: String) -> String {
        guard npub.count > 16 else { return npub }
        let prefix = npub.prefix(12)
        let suffix = npub.suffix(4)
        return "\(prefix)...\(suffix)"
    }
}
