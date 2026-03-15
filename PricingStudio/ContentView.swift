import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var authorityVM = AuthorityCollectionViewModel()
    @State private var operatorVM = OperatorCollectionViewModel()
    @State private var patronVM = PatronCollectionViewModel()
    @State private var pricingVM = PricingViewModel()
    @State private var chatVM = ChatViewModel()
    @State private var patronAccountVM = PatronAccountViewModel()
    @State private var assistantVM = AssistantViewModel()
    @State private var consultantVM = PricingConsultantViewModel()
    @State private var showingAssistant = false
    @State private var assistantFullScreen = false
    @State private var showingTrafficLog = false
    @State private var showingSettings = false

    var body: some View {
        NavigationSplitView {
            SidebarView(
                authorityVM: authorityVM,
                operatorVM: operatorVM,
                patronVM: patronVM,
                showingTrafficLog: $showingTrafficLog,
                showingSettings: $showingSettings
            )
        } detail: {
            VStack(spacing: 0) {
                Group {
                    if let auth = authorityVM.selectedAuthority {
                        ChatContainerView(identity: ChatIdentity(from: auth), chatVM: chatVM) {
                            AuthorityDetailView(authority: auth, pricingVM: pricingVM, authorityVM: authorityVM) { op in
                                operatorVM.selectedOperator = op
                            }
                        }
                    } else if let op = operatorVM.selectedOperator {
                        ChatContainerView(identity: ChatIdentity(from: op), chatVM: chatVM) {
                            PricingDetailView(target: op, viewModel: pricingVM)
                        } consultantContent: {
                            PricingConsultantView(
                                consultantVM: consultantVM,
                                context: buildConsultantContext(for: op),
                                operatorNpub: op.npub,
                                onApplyJSON: { json in
                                    pricingVM.applyConsultantJSON(json, for: op)
                                }
                            )
                        }
                    } else if let patron = patronVM.selectedPatron {
                        ChatContainerView(identity: ChatIdentity(from: patron), chatVM: chatVM, firstTabLabel: "Account") {
                            PatronDetailView(patron: patron, accountVM: patronAccountVM)
                        }
                    } else {
                        NetworkTopologyView(onNodeSelected: { npub, tier in
                            selectEntity(npub: npub, tier: tier)
                        })
                    }
                }
                .frame(maxHeight: .infinity)

                if showingTrafficLog {
                    Divider()
                    TrafficLogView(logger: TrafficLogger.shared)
                        .frame(height: 260)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        withAnimation { showingAssistant.toggle() }
                    } label: {
                        Label(
                            showingAssistant ? "Hide Assistant" : "AI Assistant",
                            systemImage: "sparkles"
                        )
                    }
                }
            }
            .inspector(isPresented: $showingAssistant) {
                AssistantPanelView(
                    assistantVM: assistantVM,
                    context: buildAppContext(),
                    onToggleFullScreen: {
                        showingAssistant = false
                        assistantFullScreen = true
                    }
                )
                .inspectorColumnWidth(min: 300, ideal: 360, max: 480)
            }
            .fullScreenCover(isPresented: $assistantFullScreen) {
                AssistantPanelView(
                    assistantVM: assistantVM,
                    context: buildAppContext(),
                    onToggleFullScreen: {
                        assistantFullScreen = false
                        showingAssistant = true
                    },
                    isFullScreen: true
                )
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
        .sheet(isPresented: $authorityVM.showingAdoptSheet) {
            if let auth = authorityVM.authorityToAdopt {
                AdoptOperatorSheet(authority: auth, viewModel: authorityVM)
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
            #if DEBUG
            OperatorStatsSheet(
                operator_: op,
                stats: PreviewData.sampleOperatorStats
            )
            #else
            OperatorStatsSheet(
                operator_: op,
                stats: nil
            )
            #endif
        }
        .sheet(isPresented: $patronVM.showingAddSheet) {
            AddPatronSheet(viewModel: patronVM)
        }
        .sheet(isPresented: $patronVM.showingEditSheet) {
            if let patron = patronVM.patronToEdit {
                EditPatronSheet(viewModel: patronVM, patron: patron)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsSheet()
        }
        .onChange(of: authorityVM.selectedAuthority) { _, newAuth in
            if let auth = newAuth {
                operatorVM.selectedOperator = nil
                patronVM.selectedPatron = nil
                pricingVM.reset()
                chatVM.switchIdentity(to: ChatIdentity(from: auth))
            }
        }
        .onChange(of: operatorVM.selectedOperator) { _, newOp in
            if let op = newOp {
                authorityVM.selectedAuthority = nil
                patronVM.selectedPatron = nil
                chatVM.switchIdentity(to: ChatIdentity(from: op))
            }
            pricingVM.reset()
        }
        .onChange(of: patronVM.selectedPatron) { _, newPatron in
            if let patron = newPatron {
                authorityVM.selectedAuthority = nil
                operatorVM.selectedOperator = nil
                pricingVM.reset()
                patronAccountVM.reset()
                chatVM.switchIdentity(to: ChatIdentity(from: patron))
            } else {
                patronAccountVM.reset()
            }
        }
        .onAppear {
            pricingVM.onAuthorityDiscovered = { npub, displayName, endpointURL in
                authorityVM.ensureAuthority(
                    npub: npub,
                    displayName: displayName,
                    endpointURL: endpointURL,
                    context: modelContext
                )
            }
            DMPollingService.shared.startPolling(modelContext: modelContext)
        }
    }

    // MARK: - App Context for AI Assistant

    private func buildAppContext() -> AppContext {
        var ctx = AppContext()

        if let auth = authorityVM.selectedAuthority {
            ctx.selectedEntityType = "Authority"
            ctx.selectedDisplayName = auth.displayName
            ctx.selectedNpub = auth.npub
        } else if let op = operatorVM.selectedOperator {
            ctx.selectedEntityType = "Operator"
            ctx.selectedDisplayName = op.displayName
            ctx.selectedNpub = op.npub
        } else if let patron = patronVM.selectedPatron {
            ctx.selectedEntityType = "Patron"
            ctx.selectedDisplayName = patron.displayName
            ctx.selectedNpub = patron.npub
        }

        if let model = pricingVM.pricingModel, let tools = model.tools {
            ctx.toolCount = tools.count
            let categories = Set(tools.map(\.category))
            ctx.categoryCount = categories.count
            let summary = tools.prefix(20).map { "\($0.toolName): \($0.priceSats)s (\($0.category))" }.joined(separator: "\n")
            ctx.toolSummary = summary
        }

        ctx.conversationCount = chatVM.conversations.count

        return ctx
    }

    // MARK: - Consultant Context

    private func buildConsultantContext(for op: Operator) -> ConsultantContext {
        var ctx = ConsultantContext()
        ctx.operatorName = op.displayName

        if let model = pricingVM.pricingModel, let tools = model.tools {
            ctx.toolSummary = tools.prefix(30).map { "\($0.toolName): \($0.priceSats) sats (\($0.category))" }.joined(separator: "\n")
            if let pipeline = model.pipeline {
                let pipelineDesc = pipeline.enumerated().map { (i, step) in
                    "  \(i + 1). \(step.type)" + (step.params.isEmpty ? "" : " — \(step.params)")
                }.joined(separator: "\n")
                ctx.currentPipeline = pipelineDesc
            }
        }

        return ctx
    }

    // MARK: - Graph Node Selection

    private func selectEntity(npub: String, tier: NetworkTier) {
        switch tier {
        case .primeAuthority, .authority:
            let descriptor = FetchDescriptor<Authority>(predicate: #Predicate { $0.npub == npub })
            if let auth = try? modelContext.fetch(descriptor).first {
                authorityVM.selectedAuthority = auth
            }
        case .operator:
            let descriptor = FetchDescriptor<Operator>(predicate: #Predicate { $0.npub == npub })
            if let op = try? modelContext.fetch(descriptor).first {
                operatorVM.selectedOperator = op
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
    @Binding var showingSettings: Bool

    private var hasSelection: Bool {
        authorityVM.selectedAuthority != nil
        || operatorVM.selectedOperator != nil
        || patronVM.selectedPatron != nil
    }

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
                HStack {
                    Button {
                        authorityVM.selectedAuthority = nil
                        operatorVM.selectedOperator = nil
                        patronVM.selectedPatron = nil
                    } label: {
                        Label("Network", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    .disabled(!hasSelection)

                    Spacer()

                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }

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
        .alert(
            "Identity Alias",
            isPresented: $patronVM.showingAliasConfirmation,
            presenting: patronVM.pendingAlias
        ) { _ in
            Button("Cancel", role: .cancel) {
                patronVM.cancelAlias()
            }
            Button("Add Alias") {
                patronVM.confirmAlias(context: modelContext)
            }
        } message: { alias in
            Text("A patron named \"\(alias.existingName)\" already uses this npub. Add \"\(alias.displayName)\" as an identity alias sharing the same key?")
        }
    }

    // MARK: - Sidebar Sections

    @ViewBuilder
    private var authoritiesSection: some View {
        Section("Authorities") {
            ForEach(authorities) { auth in
                AuthorityRowInline(
                    authority: auth,
                    isSelected: authorityVM.selectedAuthority?.npub == auth.npub,
                    onIconTapped: { authorityVM.requestEdit(auth) }
                )
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
                Button { authorityVM.showingAddSheet = true } label: {
                    Label("Add an authority", systemImage: "plus.circle")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            }
        }
    }

    @ViewBuilder
    private var operatorsSection: some View {
        Section("Operators") {
            ForEach(operators) { op in
                OperatorRowInline(
                    op: op,
                    isSelected: operatorVM.selectedOperator?.npub == op.npub,
                    onIconTapped: { operatorVM.requestEdit(op) }
                )
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
                Button { operatorVM.showingAddSheet = true } label: {
                    Label("Add an operator", systemImage: "plus.circle")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            }
        }
    }

    @ViewBuilder
    private var patronsSection: some View {
        Section("Patrons") {
            PatronSidebarView(viewModel: patronVM)

            if patrons.isEmpty {
                Button { patronVM.showingAddSheet = true } label: {
                    Label("Add a patron", systemImage: "plus.circle")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            }
        }
    }
}

// MARK: - Authority Inline Row

private struct AuthorityRowInline: View {
    let authority: Authority
    let isSelected: Bool
    var onIconTapped: (() -> Void)?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Button {
                        onIconTapped?()
                    } label: {
                        Image(systemName: "building.columns")
                            .foregroundStyle(.blue)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
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
            Spacer()
            if KeychainService.loadNsec(forNpub: authority.npub) != nil {
                Image(systemName: "checkmark.shield.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
            if DMPollingService.shared.hasUnread(for: authority.npub) {
                Image(systemName: "message.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
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
    var onIconTapped: (() -> Void)?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Button {
                        onIconTapped?()
                    } label: {
                        Image(systemName: "server.rack")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    Text(op.displayName)
                        .font(.headline)
                }
                Text(truncatedNpub(op.npub))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }
            Spacer()
            if KeychainService.loadNsec(forNpub: op.npub) != nil {
                Image(systemName: "checkmark.shield.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
            if DMPollingService.shared.hasUnread(for: op.npub) {
                Image(systemName: "message.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
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

#Preview {
    ContentView()
        .modelContainer(for: [Operator.self, Patron.self, Authority.self, Contact.self, Campaign.self], inMemory: true)
}
