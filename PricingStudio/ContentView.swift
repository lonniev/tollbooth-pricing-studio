import DPYCAuthKit
import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: \Authority.addedAt) private var authorities: [Authority]
    @Query(sort: \Operator.addedAt) private var operators: [Operator]
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
    @State private var trafficLogHeight: CGFloat = 260
    @State private var showingSettings = false
    @State private var showingPushConfirmation = false
    @State private var pushError: String?
    @State private var activeCourier: CourierParams?
    @State private var showingPushError = false
    @State private var campaignForOverview: Campaign?
    @State private var detailTab: ChatContainerTab = .pricing
    @State private var showingUnsavedEditsAlert = false
    @State private var pendingActorSwitch: (() -> Void)?
    @State private var registryAdoption: AdoptionPrefill?
    @State private var registryLookupInFlight: Bool = false

    /// On compact widths the Traffic Log presents as a sheet; on regular it
    /// stays the inline resizable panel in the detail column.
    private var compactTrafficLogBinding: Binding<Bool> {
        Binding(
            get: { horizontalSizeClass == .compact && showingTrafficLog },
            set: { showingTrafficLog = $0 }
        )
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                authorityVM: authorityVM,
                operatorVM: operatorVM,
                patronVM: patronVM,
                isConsultantStreaming: consultantVM.isStreaming,
                showingTrafficLog: $showingTrafficLog,
                showingSettings: $showingSettings,
                campaignForOverview: $campaignForOverview,
                onOpenCampaign: { op, campaign in
                    operatorVM.selectedOperator = op
                    consultantVM.loadCampaign(campaign)
                    detailTab = .consultant
                }
            )
        } detail: {
            VStack(spacing: 0) {
                Group {
                    if let auth = authorityVM.selectedAuthority {
                        authorityDetail(auth)
                    } else if let op = operatorVM.selectedOperator {
                        operatorDetail(op)
                    } else if let patron = patronVM.selectedPatron {
                        patronDetail(patron)
                    } else {
                        NetworkTopologyView(
                            onNodeSelected: { npub, tier in
                                selectEntity(npub: npub, tier: tier)
                            },
                            onOraclePrompt: { prompt in
                                // Send Oracle prompt to the AI Assistant panel
                                showingAssistant = true
                                assistantVM.sendUserMessage(
                                    "[Oracle RAG] \(prompt)",
                                    context: buildAppContext()
                                )
                            }
                        )
                    }
                }
                .frame(maxHeight: .infinity)

                if showingTrafficLog && horizontalSizeClass != .compact {
                    // Drag handle for resizing
                    HStack {
                        Spacer()
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.secondary.opacity(0.5))
                            .frame(width: 40, height: 4)
                            .padding(.vertical, 4)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let newHeight = trafficLogHeight - value.translation.height
                                trafficLogHeight = min(max(newHeight, 120), 600)
                            }
                    )

                    Divider()
                    TrafficLogView(logger: TrafficLogger.shared, filterNpub: selectedEntityNpub)
                        .frame(height: trafficLogHeight)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let params = activeCourier {
                    SecureCourierCard(
                        operatorName: params.operatorName,
                        operatorNpub: params.operatorNpub,
                        endpointURL: params.endpointURL,
                        credentialService: params.credentialService,
                        missingSecrets: params.missingSecrets,
                        greeting: params.greeting,
                        senderNpub: params.senderNpub,
                        onOpenMessages: params.senderNpub.isEmpty ? nil : { openMessagesFor(params.operatorNpub) },
                        onDismiss: { withAnimation { activeCourier = nil } }
                    )
                    .frame(width: 340)
                    .padding()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.3), value: activeCourier != nil)
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
        .confirmationDialog(
            "Push Pricing to MCP",
            isPresented: $showingPushConfirmation,
            titleVisibility: .visible
        ) {
            Button("Push to MCP") {
                guard let op = operatorVM.selectedOperator else { return }
                Task {
                    do {
                        try await pricingVM.savePricing(for: op)
                    } catch {
                        pushError = error.localizedDescription
                        showingPushError = true
                    }
                }
            }
            Button("Keep as Local Edit", role: .cancel) { }
        } message: {
            Text("The consultant's pricing has been staged locally. Push it to the operator's MCP endpoint now?")
        }
        .alert("Push Failed", isPresented: $showingPushError) {
            Button("OK") { pushError = nil }
        } message: {
            Text(pushError ?? "An unknown error occurred.")
        }
        .alert("Unsaved Pricing Edits", isPresented: $showingUnsavedEditsAlert) {
            Button("Discard", role: .destructive) {
                pricingVM.resetAllEdits()
                pendingActorSwitch?()
                pendingActorSwitch = nil
            }
            Button("Stay", role: .cancel) {
                pendingActorSwitch = nil
            }
        } message: {
            Text("You have unsaved constraint or pricing changes. Switching actors will discard them.")
        }
        .alert(
            "Delete Campaign",
            isPresented: $operatorVM.showingCampaignDeleteConfirmation,
            presenting: operatorVM.campaignToDelete
        ) { _ in
            Button("Cancel", role: .cancel) {
                operatorVM.cancelCampaignDelete()
            }
            Button("Delete", role: .destructive) {
                operatorVM.confirmCampaignDelete(for: operatorVM.selectedOperator, context: modelContext)
            }
        } message: { campaign in
            Text("Permanently delete \"\(campaign.name)\"? This campaign and its interview history cannot be recovered.")
        }
        .sheet(isPresented: compactTrafficLogBinding) {
            // Compact widths (iPhone) collapse the split view to the sidebar,
            // so the inline detail-column Traffic Log panel is unreachable —
            // present it as a sheet from the same sidebar toggle instead.
            NavigationStack {
                TrafficLogView(logger: TrafficLogger.shared, filterNpub: selectedEntityNpub)
                    .navigationTitle("Traffic Log")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: $authorityVM.showingAddSheet) {
            AddAuthoritySheet(viewModel: authorityVM)
        }
        .sheet(item: $registryAdoption) { prefill in
            AddAuthoritySheet(viewModel: authorityVM, prefill: prefill)
        }
        .sheet(isPresented: $authorityVM.showingEditSheet) {
            if let auth = authorityVM.authorityToEdit {
                EditAuthoritySheet(viewModel: authorityVM, authority: auth)
            }
        }
        .sheet(isPresented: $authorityVM.showingClaimSheet) {
            if let auth = authorityVM.authorityToClaim {
                ClaimAuthoritySheet(authority: auth, viewModel: authorityVM, chatVM: chatVM)
            }
        }
        .sheet(isPresented: $operatorVM.showingAddSheet) {
            AddOperatorSheet(viewModel: operatorVM)
        }
        .sheet(isPresented: $operatorVM.showingEditSheet) {
            if let op = operatorVM.operatorToEdit {
                EditOperatorSheet(viewModel: operatorVM, operator_: op, pricingVM: pricingVM)
            }
        }
        .sheet(item: $operatorVM.operatorForStats) { op in
            OperatorStatsSheet(
                operator_: op,
                stats: nil
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
        .sheet(isPresented: $showingSettings) {
            SettingsSheet()
        }
        // KeypairGeneratorSheet is in SidebarView (scoping)
        .onChange(of: authorityVM.selectedAuthority) { _, newAuth in
            guard let auth = newAuth else { return }
            let doSwitch = {
                operatorVM.selectedOperator = nil
                patronVM.selectedPatron = nil
                pricingVM.reset()
                chatVM.switchIdentity(to: ChatIdentity(from: auth))
                if auth.isPrime { detailTab = .pricing }
            }
            if pricingVM.hasEdits {
                pendingActorSwitch = doSwitch
                showingUnsavedEditsAlert = true
            } else {
                doSwitch()
            }
        }
        .onChange(of: operatorVM.selectedOperator) { _, newOp in
            let doSwitch = {
                if let op = newOp {
                    authorityVM.selectedAuthority = nil
                    patronVM.selectedPatron = nil
                    chatVM.switchIdentity(to: ChatIdentity(from: op))
                }
                pricingVM.reset()
                operatorVM.selectedCampaign = nil
            }
            if pricingVM.hasEdits {
                pendingActorSwitch = doSwitch
                showingUnsavedEditsAlert = true
            } else {
                doSwitch()
            }
        }
        .onChange(of: operatorVM.selectedCampaign) { old, new in
            // Auto-save outgoing campaign (skip during delete to avoid writing to a doomed object)
            if let old, !operatorVM.suppressAutoSave,
               consultantVM.currentCampaign?.persistentModelID == old.persistentModelID {
                consultantVM.autoSave(context: modelContext)
            }
            // Load incoming campaign
            if let campaign = new {
                consultantVM.loadCampaign(campaign)
            } else {
                consultantVM.clear()
            }
        }
        .onChange(of: operatorVM.deployedCampaignJSON) { _, json in
            if let json, let op = operatorVM.selectedOperator {
                pricingVM.applyConsultantJSON(json, for: op)
                operatorVM.deployedCampaignJSON = nil
            }
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
        .task {
            pricingVM.onAuthorityDiscovered = { npub, displayName, endpointURL in
                authorityVM.ensureAuthority(
                    npub: npub,
                    displayName: displayName,
                    endpointURL: endpointURL,
                    context: modelContext
                )
            }
            // Wire display name resolver using modelContext for OS notifications
            let ctx = modelContext
            DMPollingService.shared.resolveDisplayName = { key in
                Self.resolveDisplayName(key: key, context: ctx)
            }
            // Wire Oracle tool executor for AI Assistant tool_use
            // Oracle tool executor — transport handles auth via SDK authorizer
            AnthropicService.executeOracleTool = { toolName, input in
                let mcpService = MCPService()
                do {
                    let oracleURL = try await RegistryService.resolveOracleURL()
                    return try await mcpService.callToolGeneric(
                        endpointURL: oracleURL,
                        toolName: toolName
                    )
                } catch {
                    return "Oracle tool call failed: \(error.localizedDescription)"
                }
            }
            // Wrist Approval prerequisite: nsecs must be readable while the
            // iPhone is locked (watch-tap approvals). Foreground-only — the
            // re-save that changes accessibility needs the device unlocked.
            KeychainService.migrateNsecAccessibility()
            DMPollingService.shared.startPolling(modelContext: modelContext)
        }
        .overlay {
            if let campaign = campaignForOverview {
                Color.black.opacity(0.2)
                    .ignoresSafeArea()
                    .onTapGesture { campaignForOverview = nil }
                CampaignOverviewSheet(campaign: campaign) {
                    campaignForOverview = nil
                }
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: campaignForOverview?.persistentModelID)
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
        ctx.operatorEndpointURL = op.mcpEndpointURL
        ctx.operatorNpub = op.npub

        if let model = pricingVM.pricingModel, let tools = model.tools {
            ctx.toolSummary = tools.prefix(30).map { "\($0.toolName): \($0.priceSats) sats (\($0.category))" }.joined(separator: "\n")
            // Per-tool chains as of tollbooth-dpyc 0.40.0 — summarize each
            // tool's chain so the consultant sees the current shape.
            let toolsWithChains = tools.filter { !$0.chain.isEmpty }
            if !toolsWithChains.isEmpty {
                let desc = toolsWithChains.map { tool -> String in
                    let steps = tool.chain.enumerated().map { (i, step) in
                        "    \(i + 1). \(step.type)" + (step.params.isEmpty ? "" : " — \(step.params)")
                    }.joined(separator: "\n")
                    return "  \(tool.toolName):\n\(steps)"
                }.joined(separator: "\n")
                ctx.currentPipeline = "[EXISTING per-tool chains — may be outdated]\n" + desc
            }
        }

        return ctx
    }

    /// The npub of the currently selected sidebar entity, used for traffic log filtering.
    private var selectedEntityNpub: String? {
        authorityVM.selectedAuthority?.npub
            ?? operatorVM.selectedOperator?.npub
            ?? patronVM.selectedPatron?.npub
    }

    // MARK: - Graph Node Selection

    private func messagesTabLabel(npub: String) -> some View {
        let hasUnread = DMPollingService.shared.hasUnread(for: npub)
        return Text(hasUnread ? "📨 Messages" : "💬 Messages")
            .tag(ChatContainerTab.messages)
    }

    private func entityHeader(name: String, npub: String, endpoint: String?, icon: String, avatar: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let avatar, !avatar.trimmingCharacters(in: .whitespaces).isEmpty {
                    PatronAvatar(pictureURL: avatar, size: 22)
                } else {
                    Image(systemName: icon)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(name)
                    .font(.headline)
                if let member = pricingVM.memberRecord {
                    MemberInfoButton(member: member)
                }
                if let endpoint {
                    Text(endpoint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if let versions = pricingVM.serviceVersions {
                    ServiceVersionsRow(versions: versions)
                }
            }
            Text(npub)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func authorityDetail(_ auth: Authority) -> some View {
        let identity = ChatIdentity(from: auth)
        let role = auth.asRole()
        let hasOwnEndpoint = auth.mcpEndpointURL != nil

        VStack(spacing: 0) {
            entityHeader(name: auth.displayName, npub: auth.npub, endpoint: auth.mcpEndpointURL, icon: "building.columns.fill")

            Picker("View", selection: $detailTab) {
                Text("🏛️ Authority").tag(ChatContainerTab.authority)
                Text("📊 Account").tag(ChatContainerTab.invoices)
                if hasOwnEndpoint {
                    Text("🧾 Invoices").tag(ChatContainerTab.invoiceHistory)
                }
                Text("💰 Pricing").tag(ChatContainerTab.pricing)
                messagesTabLabel(npub: auth.npub)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Prime hosts the Oracle, not a tollbooth-authority MCP. It has no
            // economic surface — no balance, no pricing, no invoices — so every
            // economic tab falls back to the community canvas, even if some
            // discovery path mistakenly persisted an endpoint URL.
            let hasEconomicSurface = !auth.isPrime && auth.mcpEndpointURL != nil
            switch detailTab {
            case .authority:
                if hasEconomicSurface {
                    AuthorityDetailView(
                        authority: auth,
                        pricingVM: pricingVM,
                        authorityVM: authorityVM,
                        onOperatorSelected: { op in operatorVM.selectedOperator = op },
                        onRequestCourier: { params in withAnimation { activeCourier = params } }
                    )
                } else {
                    CommunityCanvasView()
                }
            case .pricing:
                if hasEconomicSurface {
                    PricingDetailView(target: auth, viewModel: pricingVM)
                } else {
                    CommunityCanvasView()
                }
            case .invoices:
                // The Authority's "Account" balance lives at its certification
                // source — its parent for a standard sub-Authority, itself for a
                // penultimate one — the same source the Authority and Invoices
                // tabs read. (Reading auth's OWN endpoint showed a meaningless
                // self-balance of 0 while the real balance sits at the parent.)
                if hasEconomicSurface,
                   let source = role.invoiceSources(authorities: authorities, operators: operators).first,
                   let endpoint = source.mcpEndpointURL {
                    AccountStatementView(
                        patronNpub: auth.npub,
                        serviceName: source.displayName,
                        serviceNpub: source.npub,
                        serviceEndpoint: endpoint,
                        accountVM: patronAccountVM
                    )
                } else {
                    CommunityCanvasView()
                }
            case .invoiceHistory:
                if hasEconomicSurface {
                    InvoiceListView(
                        entityNpub: role.npub,
                        sources: role.invoiceSources(authorities: authorities, operators: operators),
                        accountVM: patronAccountVM,
                        onOpenMessages: openMessagesFor
                    )
                } else {
                    CommunityCanvasView()
                }
            case .messages:
                if identity.hasNsec {
                    ChatView(chatVM: chatVM)
                        .id(identity.npub)
                        .task(id: identity.npub) { chatVM.switchIdentity(to: identity) }
                } else {
                    NoNsecView(entityName: identity.displayName)
                }
            case .consultant:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func operatorDetail(_ op: Operator) -> some View {
        let identity = ChatIdentity(from: op)
        let role = op.asRole()
        let hasAuthority = op.authorityNpub != nil

        VStack(spacing: 0) {
            entityHeader(name: op.displayName, npub: op.npub, endpoint: op.mcpEndpointURL, icon: "server.rack")

            Picker("View", selection: $detailTab) {
                if hasAuthority {
                    Text("🏛️ Authority").tag(ChatContainerTab.authority)
                }
                Text("📊 Account").tag(ChatContainerTab.invoices)
                if hasAuthority {
                    Text("🧾 Invoices").tag(ChatContainerTab.invoiceHistory)
                }
                Text("💰 Pricing").tag(ChatContainerTab.pricing)
                Text("🧭 Advisor").tag(ChatContainerTab.consultant)
                messagesTabLabel(npub: op.npub)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch detailTab {
            case .authority:
                if let authNpub = op.authorityNpub {
                    OperatorAuthorityView(operator: op, authorityNpub: authNpub)
                }
            case .pricing:
                PricingDetailView(target: op, viewModel: pricingVM, onRequestCourier: { params in
                    withAnimation { activeCourier = params }
                })
            case .consultant:
                PricingConsultantView(
                    consultantVM: consultantVM,
                    context: buildConsultantContext(for: op),
                    operatorNpub: op.npub,
                    onApplyJSON: { json in
                        pricingVM.applyConsultantJSON(json, for: op)
                        detailTab = .pricing
                        showingPushConfirmation = true
                    },
                    onDeleteCampaign: { campaign in
                        operatorVM.requestCampaignDelete(campaign)
                    }
                )
            case .messages:
                if identity.hasNsec {
                    ChatView(chatVM: chatVM)
                        .id(identity.npub)
                        .task(id: identity.npub) { chatVM.switchIdentity(to: identity) }
                } else {
                    NoNsecView(entityName: identity.displayName)
                }
            case .invoiceHistory:
                InvoiceListView(
                    entityNpub: role.npub,
                    sources: role.invoiceSources(authorities: authorities, operators: operators),
                    accountVM: patronAccountVM,
                    onOpenMessages: openMessagesFor
                )
            case .invoices:
                if let authNpub = op.authorityNpub,
                   let authority = authorities.first(where: { $0.npub == authNpub }),
                   let endpoint = authority.mcpEndpointURL {
                    AccountStatementView(
                        patronNpub: op.npub,
                        serviceName: authority.displayName,
                        serviceNpub: authNpub,
                        serviceEndpoint: endpoint,
                        accountVM: patronAccountVM,
                        onRequestCourier: { params in
                            withAnimation { activeCourier = params }
                        },
                        ownEndpoint: op.mcpEndpointURL
                    )
                } else {
                    ContentUnavailableView {
                        Label("No Authority", systemImage: "building.columns")
                    } description: {
                        Text("This operator isn’t registered with an Authority yet, so it has no cert-sat account. Register it on the Pricing tab to request adoption.")
                    } actions: {
                        Button {
                            detailTab = .pricing
                        } label: {
                            Label("Register with Authority", systemImage: "building.columns")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func patronDetail(_ patron: Patron) -> some View {
        let identity = ChatIdentity(from: patron)
        let role = patron.asRole()

        VStack(spacing: 0) {
            entityHeader(name: patron.displayName, npub: patron.npub, endpoint: nil, icon: "person.badge.key.fill", avatar: patron.pictureURL)

            Picker("View", selection: $detailTab) {
                Text("📊 Account").tag(ChatContainerTab.pricing)
                Text("🧾 Invoices").tag(ChatContainerTab.invoices)
                messagesTabLabel(npub: patron.npub)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch detailTab {
            case .pricing:
                PatronDetailView(patron: patron, accountVM: patronAccountVM, onOpenMessages: openMessagesFor, onRequestCourier: { params in
                    withAnimation { activeCourier = params }
                })
            case .invoices:
                InvoiceListView(
                    entityNpub: role.npub,
                    sources: role.invoiceSources(authorities: authorities, operators: operators),
                    accountVM: patronAccountVM,
                    onOpenMessages: openMessagesFor
                )
            case .messages:
                if identity.hasNsec {
                    ChatView(chatVM: chatVM)
                        .id(identity.npub)
                        .task(id: identity.npub) { chatVM.switchIdentity(to: identity) }
                } else {
                    NoNsecView(entityName: identity.displayName)
                }
            default:
                EmptyView()
            }
        }
    }

    private static func resolveDisplayName(key: String, context: ModelContext) -> String {
        let npub = key.hasPrefix("npub1") ? key : (try? NostrKeyService.npubFromHex(key))
        guard let npub else { return String(key.prefix(16)) + "…" }
        let patrons: [Patron] = (try? context.fetch(FetchDescriptor<Patron>())) ?? []
        if let p = patrons.first(where: { $0.npub == npub }) { return p.displayName }
        let operators: [Operator] = (try? context.fetch(FetchDescriptor<Operator>())) ?? []
        if let o = operators.first(where: { $0.npub == npub }) { return o.displayName }
        let authorities: [Authority] = (try? context.fetch(FetchDescriptor<Authority>())) ?? []
        if let a = authorities.first(where: { $0.npub == npub }) { return a.displayName }
        return String(npub.prefix(16)) + "…"
    }

    private func openMessagesFor(_ operatorNpub: String) {
        chatVM.selectedConversationId = operatorNpub
        detailTab = .messages
    }

    private func selectEntity(npub: String, tier: NetworkTier) {
        switch tier {
        case .primeAuthority, .authority:
            let descriptor = FetchDescriptor<Authority>(predicate: #Predicate { $0.npub == npub })
            if let auth = try? modelContext.fetch(descriptor).first {
                authorityVM.selectedAuthority = auth
            } else {
                // Registry-known but not locally adopted — open the adoption
                // sheet pre-filled from the dpyc-community registry entry.
                offerRegistryAdoption(npub: npub)
            }
        case .operator:
            let descriptor = FetchDescriptor<Operator>(predicate: #Predicate { $0.npub == npub })
            if let op = try? modelContext.fetch(descriptor).first {
                operatorVM.selectedOperator = op
            }
        case .oracle:
            break  // Oracle tap handled by OracleChatView sheet in NetworkTopologyView
        }
    }

    private func offerRegistryAdoption(npub: String) {
        guard !registryLookupInFlight else { return }
        registryLookupInFlight = true
        Task {
            defer { Task { @MainActor in registryLookupInFlight = false } }
            do {
                let entries = try await RegistryService.fetchRegistry()
                guard let entry = entries.first(where: { $0.npub == npub }) else { return }
                let endpoint = entry.services?.first?.url
                let prefill = AdoptionPrefill(
                    npub: entry.npub,
                    displayName: entry.display_name ?? "Authority \(entry.npub.prefix(12))…",
                    mcpEndpointURL: endpoint,
                    upstreamAuthorityNpub: entry.upstream_authority_npub,
                    role: entry.role
                )
                await MainActor.run { self.registryAdoption = prefill }
            } catch {
                // Silently ignore — tap on unknown node just does nothing,
                // same as the prior no-op behavior.
            }
        }
    }
}

// MARK: - Unified Sidebar

private struct SidebarView: View {
    @Query(sort: \Authority.addedAt) private var authorities: [Authority]
    @Query(sort: \Operator.addedAt) private var operators: [Operator]
    @Query(sort: \Patron.addedAt) private var patrons: [Patron]
    @Query(sort: \Campaign.updatedAt, order: .reverse) private var allCampaigns: [Campaign]
    @Environment(\.modelContext) private var modelContext
    @Bindable var authorityVM: AuthorityCollectionViewModel
    @Bindable var operatorVM: OperatorCollectionViewModel
    @Bindable var patronVM: PatronCollectionViewModel
    var isConsultantStreaming: Bool
    @Binding var showingTrafficLog: Bool
    @Binding var showingSettings: Bool
    @Binding var campaignForOverview: Campaign?
    var onOpenCampaign: ((Operator, Campaign) -> Void)?
    @State private var showingKeypairGenerator = false
    @State private var categoryOrder: [SidebarCategory] = [.authorities, .operators, .patrons]
    @State private var expandedCategories: Set<SidebarCategory> = Set(SidebarCategory.allCases)
    @State private var isReorderingCategories = false
    /// Npubs of Authorities whose subtree is currently collapsed in the
    /// sidebar. Empty = all branches expanded. Session-local; not persisted.
    @State private var collapsedAuthorities: Set<String> = []

    enum SidebarCategory: String, CaseIterable, Identifiable, Codable {
        case authorities, operators, patrons
        var id: String { rawValue }
        var label: String {
            switch self {
            case .authorities: "Authorities"
            case .operators: "Operators"
            case .patrons: "Patrons"
            }
        }
        var icon: String {
            switch self {
            case .authorities: "building.columns"
            case .operators: "server.rack"
            case .patrons: "person.badge.key"
            }
        }
    }

    private var hasSelection: Bool {
        authorityVM.selectedAuthority != nil
        || operatorVM.selectedOperator != nil
        || patronVM.selectedPatron != nil
    }

    private func campaigns(for op: Operator) -> [Campaign] {
        Array(allCampaigns.filter { $0.operatorNpub == op.npub && !$0.isHidden }.prefix(3))
    }

    /// Resolve campaigns selected for comparison from their PersistentIdentifiers.
    private var campaignsToCompare: [Campaign] {
        allCampaigns.filter { !$0.isHidden && operatorVM.campaignsForCompare.contains($0.persistentModelID) }
    }

    var body: some View {
        List {
            if isReorderingCategories {
                ForEach($categoryOrder) { $category in
                    Label(category.label, systemImage: category.icon)
                }
                .onMove { indices, newOffset in
                    categoryOrder.move(fromOffsets: indices, toOffset: newOffset)
                }
            } else {
                ForEach(categoryOrder) { category in
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { expandedCategories.contains(category) },
                            set: { if $0 { expandedCategories.insert(category) } else { expandedCategories.remove(category) } }
                        )
                    ) {
                        switch category {
                        case .authorities: authoritiesSectionContent
                        case .operators: operatorsSectionContent
                        case .patrons: patronsSectionContent
                        }
                    } label: {
                        Label(category.label, systemImage: category.icon)
                    }
                }
            }

            Section {
                Button {
                    showingKeypairGenerator = true
                } label: {
                    Label("Generate Nostr Keypair", systemImage: "key.fill")
                }
            }
        }
        .environment(\.editMode, isReorderingCategories ? .constant(.active) : .constant(.inactive))
        .navigationTitle("Pricing Studio")
        .toolbar { sidebarToolbarContent }
        .modifier(sidebarAlerts)
        .sheet(isPresented: $showingKeypairGenerator) {
            KeypairGeneratorSheet()
        }
        .sheet(isPresented: $operatorVM.showingCompareFromSidebar) {
            NavigationStack {
                CampaignComparisonView(campaigns: campaignsToCompare)
                    .navigationTitle("Campaign Comparison")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                operatorVM.showingCompareFromSidebar = false
                            }
                        }
                    }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var sidebarToolbarContent: some ToolbarContent {
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

                Divider()

                // Keypair generator is in the sidebar body, not the toolbar menu
                // (Swift 6.1 toolbar scoping prevents sheet presentation from menu buttons)
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

                if operatorVM.campaignsForCompare.count >= 2 {
                    Button {
                        operatorVM.showingCompareFromSidebar = true
                    } label: {
                        Label("Compare (\(operatorVM.campaignsForCompare.count))", systemImage: "arrow.left.arrow.right")
                    }
                }

                Spacer()

                Button {
                    withAnimation { isReorderingCategories.toggle() }
                } label: {
                    Label(
                        isReorderingCategories ? "Done" : "Reorder",
                        systemImage: isReorderingCategories ? "checkmark" : "arrow.up.arrow.down"
                    )
                }

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

    // MARK: - Alerts

    private var sidebarAlerts: SidebarAlertsModifier {
        SidebarAlertsModifier(
            authorityVM: authorityVM,
            operatorVM: operatorVM,
            patronVM: patronVM,
            modelContext: modelContext
        )
    }

    // MARK: - Sidebar Sections

    @ViewBuilder
    private var authoritiesSectionContent: some View {
        Group {
            ForEach(authorityTreeEntries, id: \.authority.npub) { entry in
                AuthorityRowInline(
                    authority: entry.authority,
                    isSelected: authorityVM.selectedAuthority?.npub == entry.authority.npub,
                    hasChildren: entry.hasChildren,
                    isCollapsed: collapsedAuthorities.contains(entry.authority.npub),
                    onDisclosureTapped: {
                        if collapsedAuthorities.contains(entry.authority.npub) {
                            collapsedAuthorities.remove(entry.authority.npub)
                        } else {
                            collapsedAuthorities.insert(entry.authority.npub)
                        }
                    },
                    onIconTapped: { authorityVM.requestEdit(entry.authority) }
                )
                    .padding(.leading, CGFloat(entry.depth) * 14)
                    .accessibilityIdentifier("modelListItem_\(entry.authority.npub)")
                    .contentShape(Rectangle())
                    .onTapGesture { authorityVM.selectedAuthority = entry.authority }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !entry.authority.isPrime {
                            Button(role: .destructive) {
                                authorityVM.requestDelete(entry.authority)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .contextMenu {
                        Button {
                            authorityVM.requestEdit(entry.authority)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        if !entry.authority.isPrime {
                            Divider()
                            Button(role: .destructive) {
                                authorityVM.requestDelete(entry.authority)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
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

    /// Authorities flattened in depth-first chain order:
    /// Prime first with its descendants nested under it, then unchained
    /// authorities (no parent and not Prime) sorted alphabetically by
    /// displayName. Descendants of a collapsed Authority are omitted from
    /// the result so the sidebar hides them entirely. Cycle-guarded so a
    /// malformed parent chain can't loop.
    private var authorityTreeEntries: [AuthorityTreeEntry] {
        let byNpub = Dictionary(uniqueKeysWithValues: authorities.map { ($0.npub, $0) })
        let childrenByParent = Dictionary(grouping: authorities.compactMap { auth -> (String, Authority)? in
            guard let parent = auth.parentAuthorityNpub, !parent.isEmpty else { return nil }
            return (parent, auth)
        }, by: { $0.0 }).mapValues { $0.map(\.1).sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending } }

        var result: [AuthorityTreeEntry] = []

        func visit(_ auth: Authority, depth: Int, visited: Set<String>) {
            guard !visited.contains(auth.npub) else { return }
            let kids = childrenByParent[auth.npub] ?? []
            result.append(AuthorityTreeEntry(authority: auth, depth: depth, hasChildren: !kids.isEmpty))
            guard !collapsedAuthorities.contains(auth.npub) else { return }
            let next = visited.union([auth.npub])
            for child in kids {
                visit(child, depth: depth + 1, visited: next)
            }
        }

        if let prime = authorities.first(where: { $0.isPrime }) {
            visit(prime, depth: 0, visited: [])
        }

        let rooted = Set(result.map { $0.authority.npub })
        let unchained = authorities
            .filter { !rooted.contains($0.npub) }
            .filter { auth in
                // Treat as unchained if parent is missing OR points outside
                // the locally known authority set.
                guard let parent = auth.parentAuthorityNpub, !parent.isEmpty else { return true }
                return byNpub[parent] == nil
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        for auth in unchained {
            visit(auth, depth: 0, visited: Set(result.map(\.authority.npub)))
        }

        return result
    }

    @ViewBuilder
    private var operatorsSectionContent: some View {
        Group {
            ForEach(operators) { op in
                OperatorRowInline(
                    op: op,
                    isSelected: operatorVM.selectedOperator?.npub == op.npub,
                    deployedCampaignName: op.deployedCampaignName,
                    onIconTapped: { operatorVM.requestEdit(op) }
                )
                    .accessibilityIdentifier("modelListItem_\(op.npub)")
                    .contentShape(Rectangle())
                    .onTapGesture {
                        operatorVM.selectedOperator = op
                        operatorVM.selectedCampaign = nil
                    }
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

                // Campaign slots indented under operator
                ForEach(campaigns(for: op), id: \.persistentModelID) { campaign in
                    CampaignSlotRow(
                        campaign: campaign,
                        isSelected: operatorVM.selectedCampaign?.persistentModelID == campaign.persistentModelID,
                        isDeployed: campaign.isDeployed,
                        isComparing: operatorVM.campaignsForCompare.contains(campaign.persistentModelID)
                    )
                    .padding(.leading, 28)
                    .contentShape(Rectangle())
                    .opacity(isConsultantStreaming ? 0.5 : 1.0)
                    .onTapGesture {
                        guard !isConsultantStreaming else { return }
                        onOpenCampaign?(op, campaign)
                    }
                    .contextMenu {
                        Button {
                            operatorVM.deployCampaign(campaign, for: op, context: modelContext)
                        } label: {
                            Label("Deploy to Operator", systemImage: "arrow.up.to.line")
                        }
                        Button {
                            operatorVM.toggleCompare(campaign)
                        } label: {
                            if operatorVM.campaignsForCompare.contains(campaign.persistentModelID) {
                                Label("Remove from Compare", systemImage: "minus.circle")
                            } else {
                                Label("Add to Compare", systemImage: "plus.circle")
                            }
                        }
                        .disabled(!operatorVM.campaignsForCompare.contains(campaign.persistentModelID)
                                  && operatorVM.campaignsForCompare.count >= 3)

                        Button {
                            campaignForOverview = campaign
                        } label: {
                            Label("Campaign Overview", systemImage: "chart.bar.doc.horizontal")
                        }

                        Divider()

                        Button {
                            operatorVM.putAwayCampaign(campaign, for: op, context: modelContext)
                        } label: {
                            Label("Put Away", systemImage: "tray.and.arrow.down")
                        }
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
    private var patronsSectionContent: some View {
        Group {
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

// MARK: - Authority Tree Entry

private struct AuthorityTreeEntry {
    let authority: Authority
    let depth: Int
    let hasChildren: Bool
}

// MARK: - Authority Inline Row

private struct AuthorityRowInline: View {
    let authority: Authority
    let isSelected: Bool
    var hasChildren: Bool = false
    var isCollapsed: Bool = false
    var onDisclosureTapped: (() -> Void)?
    var onIconTapped: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            // Disclosure chevron — only meaningful when this Authority has
            // children. Reserve the same footprint when there are none so
            // sibling rows line up cleanly.
            if hasChildren {
                Button {
                    onDisclosureTapped?()
                } label: {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCollapsed ? "Expand subtree" : "Collapse subtree")
                .accessibilityIdentifier("authorityDisclosure_\(authority.npub)")
            } else {
                Color.clear.frame(width: 14, height: 14)
            }

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
                    .help("Signing key (nsec) stored in your Keychain")
            }
            if (DMPollingService.shared.unreadCounts[authority.npub] ?? 0) > 0 {
                Image(systemName: "envelope.badge.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("You have new Nostr DMs")
                    .accessibilityIdentifier("dmIndicator_\(authority.npub)")
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
    var deployedCampaignName: String?
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
                if let campaignName = deployedCampaignName {
                    Text(campaignName)
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .lineLimit(1)
                }
            }
            Spacer()
            if KeychainService.loadNsec(forNpub: op.npub) != nil {
                Image(systemName: "checkmark.shield.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .help("Signing key (nsec) stored in your Keychain")
            }
            if (DMPollingService.shared.unreadCounts[op.npub] ?? 0) > 0 {
                Image(systemName: "envelope.badge.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("You have new Nostr DMs")
                    .accessibilityIdentifier("dmIndicator_\(op.npub)")
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

// MARK: - Campaign Slot Row

private struct CampaignSlotRow: View {
    let campaign: Campaign
    let isSelected: Bool
    let isDeployed: Bool
    let isComparing: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(campaign.name)
                    .font(.subheadline)
                    .lineLimit(1)
                stageLabel
            }
            Spacer()
            if isComparing {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
            if isDeployed {
                Text("LIVE")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.2))
                    .foregroundStyle(.green)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.10) : nil)
    }

    @ViewBuilder
    private var stageLabel: some View {
        if let progress = campaign.interviewProgress {
            if progress.stageNumber >= 6 {
                Label("Complete", systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            } else {
                Text("Stage \(progress.stageNumber)/6")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("New")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Sidebar Alerts Modifier

private struct SidebarAlertsModifier: ViewModifier {
    @Bindable var authorityVM: AuthorityCollectionViewModel
    @Bindable var operatorVM: OperatorCollectionViewModel
    @Bindable var patronVM: PatronCollectionViewModel
    var modelContext: ModelContext

    func body(content: Content) -> some View {
        content
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
                "Duplicate Identity",
                isPresented: $patronVM.showingDuplicateAlert
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(patronVM.duplicateAlertMessage)
            }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Operator.self, Patron.self, Authority.self, Contact.self, Campaign.self], inMemory: true)
}
