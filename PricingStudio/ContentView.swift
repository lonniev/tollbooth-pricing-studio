import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var authorityVM = AuthorityCollectionViewModel()
    @State private var operatorVM = OperatorCollectionViewModel()
    @State private var patronVM = PatronCollectionViewModel()
    @State private var pricingVM = PricingViewModel()
    @State private var showingTrafficLog = false

    var body: some View {
        NavigationSplitView {
            SidebarView(
                authorityVM: authorityVM,
                operatorVM: operatorVM,
                patronVM: patronVM,
                showingTrafficLog: $showingTrafficLog
            )
        } detail: {
            VStack(spacing: 0) {
                Group {
                    if let auth = authorityVM.selectedAuthority {
                        AuthorityDetailCard(authority: auth)
                    } else if let op = operatorVM.selectedOperator {
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
        .sheet(isPresented: $authorityVM.showingAddSheet) {
            AddAuthoritySheet(viewModel: authorityVM)
        }
        .sheet(isPresented: $authorityVM.showingEditSheet) {
            if let auth = authorityVM.authorityToEdit {
                EditAuthoritySheet(viewModel: authorityVM, authority: auth)
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
        .onChange(of: authorityVM.selectedAuthority) { _, newAuth in
            if newAuth != nil {
                operatorVM.selectedOperator = nil
                patronVM.selectedPatron = nil
                pricingVM.reset()
            }
        }
        .onChange(of: operatorVM.selectedOperator) { _, newOp in
            if newOp != nil {
                authorityVM.selectedAuthority = nil
                patronVM.selectedPatron = nil
            }
            if newOp == nil {
                pricingVM.reset()
            }
        }
        .onChange(of: patronVM.selectedPatron) { _, newPatron in
            if newPatron != nil {
                authorityVM.selectedAuthority = nil
                operatorVM.selectedOperator = nil
                pricingVM.reset()
            }
        }
    }
}

// MARK: - Unified Sidebar

private struct SidebarView: View {
    @Query(sort: \Authority.addedAt) private var authorities: [Authority]
    @Query(sort: \Operator.addedAt) private var operators: [Operator]
    @Query(sort: \Patron.addedAt) private var patrons: [Patron]
    @Environment(\.modelContext) private var modelContext
    @Bindable var authorityVM: AuthorityCollectionViewModel
    @Bindable var operatorVM: OperatorCollectionViewModel
    @Bindable var patronVM: PatronCollectionViewModel
    @Binding var showingTrafficLog: Bool

    var body: some View {
        List {
            authoritiesSection
            operatorsSection
            patronsSection
        }
        .navigationTitle("Pricing Studio")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        authorityVM.showingAddSheet = true
                    } label: {
                        Label("Add Authority", systemImage: "building.columns")
                    }
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
            "Delete Authority",
            isPresented: $authorityVM.showingDeleteConfirmation,
            presenting: authorityVM.authorityToDelete
        ) { _ in
            Button("Cancel", role: .cancel) {
                authorityVM.cancelDelete()
            }
            Button("Delete", role: .destructive) {
                authorityVM.confirmDelete(context: modelContext)
            }
        } message: { auth in
            Text("Delete \"\(auth.displayName)\"? Any saved OAuth token for this authority will also be removed.")
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

    // MARK: - Sidebar Sections

    @ViewBuilder
    private var authoritiesSection: some View {
        Section("Authorities") {
            ForEach(authorities) { auth in
                AuthorityRowInline(authority: auth, isSelected: authorityVM.selectedAuthority?.npub == auth.npub)
                    .contentShape(Rectangle())
                    .onTapGesture { authorityVM.selectedAuthority = auth }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            authorityVM.requestDelete(auth)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button {
                            authorityVM.requestEdit(auth)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        Divider()
                        Button(role: .destructive) {
                            authorityVM.requestDelete(auth)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }

            if authorities.isEmpty {
                Text("No authorities yet")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
        }
    }

    @ViewBuilder
    private var operatorsSection: some View {
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
    }

    @ViewBuilder
    private var patronsSection: some View {
        Section("Patrons") {
            PatronSidebarView(viewModel: patronVM)

            if patrons.isEmpty {
                Text("No patrons yet")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
        }
    }
}

// MARK: - Authority Inline Row

private struct AuthorityRowInline: View {
    let authority: Authority
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "building.columns")
                    .foregroundStyle(.blue)
                    .font(.caption)
                Text(authority.displayName)
                    .font(.headline)
            }
            Text(truncatedNpub(authority.npub))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospaced()
            if authority.isAutoDiscovered {
                Label("Auto-discovered", systemImage: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
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

// MARK: - Authority Detail Card

private struct AuthorityDetailCard: View {
    let authority: Authority

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "building.columns.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text(authority.displayName)
                .font(.title.bold())

            VStack(spacing: 8) {
                Text(authority.npub)
                    .font(.callout)
                    .monospaced()
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text("Added \(authority.addedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if authority.isAutoDiscovered {
                Label("Auto-discovered from operator lookup", systemImage: "sparkles")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let endpoint = authority.mcpEndpointURL {
                Label(endpoint, systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(authority.displayName)
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
        .modelContainer(for: [Operator.self, Patron.self, Authority.self], inMemory: true)
}
