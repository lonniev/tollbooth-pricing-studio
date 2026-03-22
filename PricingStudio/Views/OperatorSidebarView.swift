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
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            viewModel.requestDelete(op)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button {
                            viewModel.requestEdit(op)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        Button {
                            viewModel.requestStats(op)
                        } label: {
                            Label("View Details", systemImage: "info.circle")
                        }
                        Divider()
                        Button(role: .destructive) {
                            viewModel.requestDelete(op)
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
        .alert(
            "Delete Operator",
            isPresented: $viewModel.showingDeleteConfirmation,
            presenting: viewModel.operatorToDelete
        ) { op in
            Button("Cancel", role: .cancel) {
                viewModel.cancelDelete()
            }
            Button("Delete", role: .destructive) {
                viewModel.confirmDelete(context: modelContext)
            }
        } message: { op in
            Text("Delete \"\(op.displayName)\"? Any saved OAuth token for this operator will also be removed.")
        }
    }
}

private struct OperatorRow: View {
    let op: Operator

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(op.displayName)
                    .font(.headline)
                if DMPollingService.shared.hasUnread(for: op.npub) {
                    Image(systemName: "envelope.badge.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
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
