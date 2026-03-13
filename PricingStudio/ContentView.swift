import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var operatorVM = OperatorCollectionViewModel()
    @State private var patronVM = PatronCollectionViewModel()
    @State private var pricingVM = PricingViewModel()
    @State private var showingTrafficLog = false

    var body: some View {
        NavigationSplitView {
            SidebarView(
                operatorVM: operatorVM,
                patronVM: patronVM,
                showingTrafficLog: $showingTrafficLog
            )
        } detail: {
            VStack(spacing: 0) {
                Group {
                    if let op = operatorVM.selectedOperator {
                        PricingDetailView(op: op, viewModel: pricingVM)
                    } else if let patron = patronVM.selectedPatron {
                        PatronDetailCard(patron: patron)
                    } else {
                        EmptyStateView()
                    }
                }
                .frame(maxHeight: .infinity)

                if showingTrafficLog {
                    Divider()
                    TrafficLogView(logger: TrafficLogger.shared)
                        .frame(height: 260)
                }
            }
        }
        .sheet(isPresented: $operatorVM.showingAddSheet) {
            AddOperatorSheet(viewModel: operatorVM)
        }
        .sheet(isPresented: $operatorVM.showingEditSheet) {
            if let op = operatorVM.operatorToEdit {
                EditOperatorSheet(viewModel: operatorVM, operator_: op)
            }
        }
        .sheet(item: $operatorVM.operatorForStats) { op in
            OperatorStatsSheet(
                operator_: op,
                stats: PreviewData.sampleOperatorStats
            )
        }
        .sheet(isPresented: $patronVM.showingAddSheet) {
            AddPatronSheet(viewModel: patronVM)
        }
        .sheet(isPresented: $patronVM.showingEditSheet) {
            if let patron = patronVM.patronToEdit {
                EditPatronSheet(viewModel: patronVM, patron: patron)
            }
        }
        .onChange(of: operatorVM.selectedOperator) { _, newOp in
            if newOp != nil {
                patronVM.selectedPatron = nil
            }
            if newOp == nil {
                pricingVM.reset()
            }
        }
        .onChange(of: patronVM.selectedPatron) { _, newPatron in
            if newPatron != nil {
                operatorVM.selectedOperator = nil
                pricingVM.reset()
            }
        }
    }
}

// MARK: - Unified Sidebar

private struct SidebarView: View {
    @Query(sort: \Operator.addedAt) private var operators: [Operator]
    @Query(sort: \Patron.addedAt) private var patrons: [Patron]
    @Environment(\.modelContext) private var modelContext
    @Bindable var operatorVM: OperatorCollectionViewModel
    @Bindable var patronVM: PatronCollectionViewModel
    @Binding var showingTrafficLog: Bool

    var body: some View {
        List {
            Section("Operators") {
                ForEach(operators) { op in
                    OperatorRowInline(op: op, isSelected: operatorVM.selectedOperator?.npub == op.npub)
                        .contentShape(Rectangle())
                        .onTapGesture { operatorVM.selectedOperator = op }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                operatorVM.requestDelete(op)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button {
                                operatorVM.requestEdit(op)
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            Button {
                                operatorVM.requestStats(op)
                            } label: {
                                Label("View Details", systemImage: "info.circle")
                            }
                            Divider()
                            Button(role: .destructive) {
                                operatorVM.requestDelete(op)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }

                if operators.isEmpty {
                    Text("No operators yet")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            }

            Section("Patrons") {
                PatronSidebarView(viewModel: patronVM)

                if patrons.isEmpty {
                    Text("No patrons yet")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            }
        }
        .navigationTitle("Pricing Studio")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        operatorVM.showingAddSheet = true
                    } label: {
                        Label("Add Operator", systemImage: "server.rack")
                    }
                    Button {
                        patronVM.showingAddSheet = true
                    } label: {
                        Label("Add Patron", systemImage: "person.badge.key")
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Button {
                    withAnimation { showingTrafficLog.toggle() }
                } label: {
                    Label(
                        showingTrafficLog ? "Hide Traffic Log" : "Show Traffic Log",
                        systemImage: showingTrafficLog
                            ? "antenna.radiowaves.left.and.right.slash"
                            : "antenna.radiowaves.left.and.right"
                    )
                }
            }
        }
        .alert(
            "Delete Operator",
            isPresented: $operatorVM.showingDeleteConfirmation,
            presenting: operatorVM.operatorToDelete
        ) { _ in
            Button("Cancel", role: .cancel) {
                operatorVM.cancelDelete()
            }
            Button("Delete", role: .destructive) {
                operatorVM.confirmDelete(context: modelContext)
            }
        } message: { op in
            Text("Delete \"\(op.displayName)\"? Any saved OAuth token and nsec for this operator will also be removed.")
        }
        .alert(
            "Delete Patron",
            isPresented: $patronVM.showingDeleteConfirmation,
            presenting: patronVM.patronToDelete
        ) { _ in
            Button("Cancel", role: .cancel) {
                patronVM.cancelDelete()
            }
            Button("Delete", role: .destructive) {
                patronVM.confirmDelete(context: modelContext)
            }
        } message: { patron in
            Text("Delete \"\(patron.displayName)\"? Any saved nsec for this patron will also be removed.")
        }
    }
}

// MARK: - Inline Row (for unified list without selection binding)

private struct OperatorRowInline: View {
    let op: Operator
    let isSelected: Bool

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
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.15) : nil)
    }

    private func truncatedNpub(_ npub: String) -> String {
        guard npub.count > 16 else { return npub }
        let prefix = npub.prefix(12)
        let suffix = npub.suffix(4)
        return "\(prefix)...\(suffix)"
    }
}

// MARK: - Patron Detail Card

private struct PatronDetailCard: View {
    let patron: Patron

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)

            Text(patron.displayName)
                .font(.title.bold())

            VStack(spacing: 8) {
                Text(patron.npub)
                    .font(.callout)
                    .monospaced()
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text("Added \(patron.addedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if KeychainService.loadNsec(forNpub: patron.npub) != nil {
                Label("nsec stored in Keychain", systemImage: "checkmark.shield.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(patron.displayName)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Operator.self, Patron.self], inMemory: true)
}
