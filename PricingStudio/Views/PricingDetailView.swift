import SwiftUI
import SwiftData

struct PricingDetailView: View {
    let target: any PricingTarget
    @Bindable var viewModel: PricingViewModel
    var onRequestCourier: ((CourierParams) -> Void)?
    @State private var isEditingPipeline = false
    @State private var saveError: String?
    @State private var showSaveSuccess = false
    @State private var showingSaveConfirmation = false
    @State private var showingDiff = false
    @State private var showingReconciliation = false
    @State private var showingReconcileConfirmation = false
    @State private var reconciliationVM = ReconciliationViewModel()
    @State private var showingEditRegistration = false
    @State private var showingDeregisterConfirm = false
    @State private var deregisterError: String?
    @State private var deregisterProofRemedy: DeregisterProofRemedy?
    @State private var showingRecoverPayment = false
    @State private var onboardingStatus: MCPService.OnboardingStatus?
    @State private var onboardingLoading = false
    @State private var isInitializing = false
    @State private var showingResetConfirm = false
    @State private var showingOnboardingSheet = false
    @State private var authorityBalanceVM = AuthorityBalanceViewModel()
    @State private var showingAuthorityTopOff = false
    @State private var couponVM = CouponViewModel()
    @State private var showingCoupons = false
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle:
                ProgressView()

            case .loading(let step):
                ConnectionStatusView(step: step, onCancel: { viewModel.cancel() })

            case .loaded(let model):
                loadedContent(model)

            case .error(let message):
                errorContent(message)

            case .notRegistered:
                notRegisteredContent

            case .registeredNotConfigured:
                registeredNotConfiguredContent

            case .cancelled:
                ContentUnavailableView {
                    Label("Loading Cancelled", systemImage: "stop.circle")
                } description: {
                    Text("The connection was cancelled before it could complete.")
                } actions: {
                    Button("Retry") {
                        viewModel.retry(for: target)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        // navigationTitle removed — shared entityHeader provides the actor name
        .onAppear {
            // Ensure we're showing the right target's data — shared VM may
            // still hold data from a previously viewed operator/authority.
            // Also restart if stuck in .loading from a previous cancelled navigation.
            let needsLoad: Bool = {
                if case .idle = viewModel.state { return true }
                if case .loading = viewModel.state { return true }
                if case .cancelled = viewModel.state { return true }
                if viewModel.currentOperatorNpub != target.npub { return true }
                return false
            }()
            if needsLoad {
                viewModel.startLoading(for: target)
            }
        }
        .onChange(of: target.npub) { _, _ in
            viewModel.startLoading(for: target)
        }
        // Inline register/switch flow (Authority-side, immediate consent),
        // driven by the loaded "Switch Authority" button. Hoisted to body so
        // it's mounted in every state.
        .sheet(isPresented: $showingAdoptionRequest, onDismiss: {
            // After a successful (re-)registration / switch, the sheet sets
            // op.authorityNpub. Transition directly to registeredNotConfigured
            // so the user doesn't see a stale GitHub registry cache.
            if let op = target as? Operator, op.authorityNpub != nil {
                viewModel.markRegisteredNotConfigured()
            }
        }) {
            RegisterOperatorSheet(operatorTarget: target, pricingVM: viewModel)
        }
        // Deferred courtship (operator-initiated request_adoption → the
        // Authority owner's Pending Adoptions queue), driven by the orphan
        // "Request Adoption" button. The operator stays orphaned until
        // approved, so reload to reflect current state on dismiss.
        .sheet(isPresented: $showingSeekAdoption, onDismiss: {
            viewModel.startLoading(for: target)
        }) {
            SeekAdoptionSheet(operatorTarget: target, pricingVM: viewModel)
        }
    }

    private var editSummary: String {
        var parts: [String] = []
        if !viewModel.localEdits.isEmpty {
            let n = viewModel.localEdits.count
            parts.append("\(n) tool \(n == 1 ? "edit" : "edits")")
        }
        if !viewModel.localRemovals.isEmpty {
            let n = viewModel.localRemovals.count
            parts.append("\(n) \(n == 1 ? "removal" : "removals")")
        }
        if viewModel.hasChainEdits {
            parts.append("constraint chain changes")
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func loadedContent(_ model: PricingModelResponse) -> some View {
        if model.status == "ok", let tools = model.tools {
            // Merge in new tools from reconciliation that aren't in the stored model
            let storedNames = Set(tools.map(\.toolName))
            let newFromEdits = viewModel.localEdits.values.filter { !storedNames.contains($0.toolName) }
            let allTools = tools + newFromEdits.sorted(by: { $0.toolName < $1.toolName })

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if let name = model.name {
                            modelHeader(name: name, isActive: model.isActive ?? false, member: viewModel.memberRecord, source: model.source)
                        }

                        // Authority balance is on the Authority tab now

                        if let endpoint = target.mcpEndpointURL {
                            NotarizationStatusView(operatorNpub: target.npub, endpointURL: endpoint)
                        }

                        trancheLifetimeSection(model: model)

                        couponsSection

                        // Constraint chains now live on each tool (0.40.0+);
                        // drill into a row from the list below to edit its
                        // chain.
                        ToolPriceListView(
                            tools: allTools,
                            viewModel: viewModel,
                            target: target,
                            couponViewModel: couponVM,
                        )
                    }
                    .padding()
                }
                .refreshable {
                    viewModel.retry(for: target)
                }

            }
            .sheet(isPresented: $showingDiff) {
                NavigationStack {
                    PricingDiffView(
                        modelA: model,
                        modelB: viewModel.mergedPreview(from: model),
                        labelA: "Current",
                        labelB: "With Edits"
                    )
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingDiff = false }
                        }
                    }
                }
            }
            .sheet(isPresented: $showingReconciliation) {
                ReconciliationSheet(
                    viewModel: reconciliationVM,
                    storedModel: model,
                    onApply: { suggested, mismatch in
                        viewModel.applyReconciliation(
                            suggestedTools: suggested,
                            mismatch: mismatch,
                            storedModel: model
                        )
                    }
                )
            }
            .alert("Save Failed", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK") { saveError = nil }
            } message: {
                if let saveError {
                    Text(saveError)
                }
            }
        } else if target is Operator {
            // Operator connected but has no pricing model — show onboarding
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "tag.slash")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)

                    Text("No Pricing Model")
                        .font(.title2.bold())

                    Text("**\(target.displayName)** is online but hasn't published a pricing model yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)

                    if let url = target.mcpEndpointURL, !url.isEmpty,
                       let link = URL(string: url) {
                        Link(url, destination: link)
                            .font(.caption)
                            .monospaced()
                            .foregroundStyle(.blue)
                    }

                    Text(target.npub)
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)

                    // Show onboarding checklist
                    if onboardingLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Checking configuration...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let status = onboardingStatus {
                        onboardingChecklist(status)
                    }

                    HStack(spacing: 12) {
                        Button("Retry") {
                            viewModel.retry(for: target)
                        }
                        .buttonStyle(.bordered)

                        if KeychainService.loadNsec(forNpub: target.npub) != nil {
                            Button {
                                initializePricingModel(for: target)
                            } label: {
                                Label("Initialize Pricing", systemImage: "plus.circle.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    if isInitializing {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Initializing pricing model...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            }
            .task {
                if onboardingStatus == nil, target.mcpEndpointURL != nil {
                    await loadOnboardingStatus()
                }
            }
        } else {
            ContentUnavailableView(
                "No Pricing Model",
                systemImage: "tag.slash",
                description: Text("This entity hasn't published a pricing model yet.")
            )
        }
    }

    private var unifiedSaveBar: some View {
        HStack {
            if viewModel.campaignApplied {
                Label("Campaign ready", systemImage: "checkmark.seal.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
            } else {
                Text(editSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if showSaveSuccess {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Button("Compare") {
                showingDiff = true
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Reset All") {
                viewModel.resetAllEdits()
                isEditingPipeline = false
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Save to Operator") {
                showingSaveConfirmation = true
            }
            .accessibilityIdentifier("applyButton")
            .font(.caption)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .confirmationDialog(
                "Save Changes",
                isPresented: $showingSaveConfirmation,
                titleVisibility: .visible
            ) {
                Button("Save to \(target.displayName)") {
                    Task {
                        do {
                            try await viewModel.savePricing(for: target)
                            isEditingPipeline = false
                            viewModel.campaignApplied = false
                            showSaveSuccess = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                showSaveSuccess = false
                            }
                        } catch {
                            saveError = error.localizedDescription
                        }
                    }
                }
                .accessibilityIdentifier("confirmApplyButton")
                Button("Cancel", role: .cancel) { }
                    .accessibilityIdentifier("cancelApplyButton")
            } message: {
                Text("This will overwrite the operator's active pricing model with your \(editSummary). This action cannot be undone.")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Authority Balance Section

    @ViewBuilder
    private func authorityBalanceSection(operatorNpub: String, authorityNpub: String) -> some View {
        let authority = resolveAuthority(npub: authorityNpub)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "building.columns.fill")
                    .foregroundStyle(.blue)
                Text("Authority Account")
                    .font(.subheadline.bold())
                Spacer()

                switch authorityBalanceVM.balanceState {
                case .idle:
                    EmptyView()
                case .loading:
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Brr\u{2026}").font(.caption).foregroundStyle(.secondary)
                    }
                case .loaded(let result):
                    Text("\(result.balanceApiSats) sats")
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(result.balanceApiSats > 0 ? .primary : .red)
                case .error(let msg):
                    Label("Error", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .help(msg)
                }
            }

            Text(authority?.displayName ?? String(authorityNpub.prefix(20)) + "...")
                .font(.caption)
                .foregroundStyle(.secondary)

            if case .loaded(let result) = authorityBalanceVM.balanceState {
                HStack(spacing: 12) {
                    Button {
                        showingAuthorityTopOff = true
                    } label: {
                        Label("Top Up", systemImage: "plus.circle.fill")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(result.balanceApiSats < 100 ? .orange : .accentColor)
                    .controlSize(.small)

                    if !result.pendingInvoiceIds.isEmpty, let auth = authority {
                        Button {
                            Task { await authorityBalanceVM.reconcile(authority: auth, pendingIds: result.pendingInvoiceIds) }
                        } label: {
                            if authorityBalanceVM.isReconciling {
                                ProgressView().controlSize(.mini)
                            } else {
                                Label("Reconcile (\(result.pendingInvoiceIds.count))", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.caption.bold())
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(authorityBalanceVM.isReconciling)
                    }
                }

                if let rr = authorityBalanceVM.reconcileResult {
                    HStack(spacing: 6) {
                        if rr.settled > 0 {
                            Label("+\(rr.creditsGained) sats", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        if rr.expired > 0 {
                            Label("\(rr.expired) expired", systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                    .font(.caption2)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task {
            if case .idle = authorityBalanceVM.balanceState, let auth = authority {
                await authorityBalanceVM.loadBalance(for: auth)
            }
        }
        .sheet(isPresented: $showingAuthorityTopOff) {
            if let auth = authority {
                PurchaseCreditsSheet(
                    cashierName: auth.displayName,
                    cashierNpub: auth.npub,
                    endpoint: auth.mcpEndpointURL ?? "",
                    purchaserNpub: operatorNpub,
                    beneficiaryBadge: .operator,
                    cashierBadge: .authority,
                    presets: [500, 1000, 5000, 10000],
                    onSettled: {
                        Task {
                            await authorityBalanceVM.loadCertificationBalance(
                                authorityNpub: operatorNpub,
                                source: InvoiceSource(
                                    npub: auth.npub,
                                    displayName: auth.displayName,
                                    mcpEndpointURL: auth.mcpEndpointURL
                                )
                            )
                        }
                    }
                )
            }
        }
    }

    private func resolveAuthority(npub: String) -> Authority? {
        let descriptor = FetchDescriptor<Authority>(predicate: #Predicate { $0.npub == npub })
        return try? modelContext.fetch(descriptor).first
    }

    @ViewBuilder
    private var couponsSection: some View {
        if let raw = target.mcpEndpointURL, let endpoint = URL(string: raw) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "ticket")
                        .foregroundStyle(.secondary)
                    Text("Coupons")
                        .font(.subheadline.bold())
                    Spacer()
                    Button {
                        couponVM.refresh(endpointURL: endpoint, operatorNpub: target.npub)
                        showingCoupons = true
                    } label: {
                        let n = couponVM.coupons.count
                        Text(n == 0 ? "Manage…" : "\(n) coupon\(n == 1 ? "" : "s") · Manage…")
                            .font(.caption)
                    }
                    .accessibilityIdentifier("manageCouponsButton")
                }
                Text("Mint and edit discount codes that patrons redeem once. The chain editor's coupon constraint references coupons by id.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(.separator), lineWidth: 0.5)
            )
            .onAppear {
                // Hydrate quietly so the chain editor's picker has data.
                if case .idle = couponVM.loadState {
                    couponVM.refresh(endpointURL: endpoint, operatorNpub: target.npub)
                }
            }
            .sheet(isPresented: $showingCoupons) {
                NavigationStack {
                    CouponsView(
                        endpointURL: endpoint,
                        operatorNpub: target.npub,
                        viewModel: couponVM,
                    )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showingCoupons = false }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func trancheLifetimeSection(model: PricingModelResponse) -> some View {
        let effective = viewModel.localTrancheLifetime ?? model.trancheLifetime
        let isEnabled = effective?.ttlDays != nil

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "hourglass")
                    .foregroundStyle(.secondary)
                Text("Tranche Lifetime")
                    .font(.subheadline.bold())
                Spacer()
                if isEditingPipeline {
                    Toggle("", isOn: Binding(
                        get: { isEnabled },
                        set: { on in
                            if on {
                                viewModel.localTrancheLifetime = .default
                            } else {
                                viewModel.localTrancheLifetime = TrancheLifetime(ttlDays: nil)
                            }
                        }
                    ))
                    .labelsHidden()
                }
            }

            if isEnabled, let tl = effective {
                VStack(alignment: .leading, spacing: 4) {
                    if isEditingPipeline {
                        HStack {
                            Text("Expires after")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            TextField("days", value: Binding(
                                get: { tl.ttlDays ?? 15 },
                                set: { days in
                                    var updated = viewModel.localTrancheLifetime ?? tl
                                    updated.ttlDays = max(updated.minDays, min(updated.maxDays, days))
                                    viewModel.localTrancheLifetime = updated
                                }
                            ), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .keyboardType(.numberPad)
                            Text("days")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    } else {
                        HStack(spacing: 12) {
                            Label("\(tl.ttlDays ?? 15) days", systemImage: "calendar.badge.clock")
                                .font(.subheadline.monospacedDigit())
                            Text("target \(Int(tl.targetUsagePct * 100))% usage")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if !isEditingPipeline {
                Text("Credits never expire")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func modelHeader(name: String, isActive: Bool, member: MemberRecord?, source: PricingSource) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.subheadline.bold())
                HStack(spacing: 12) {
                    if isActive {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    }
                    Label(
                        source == .stored ? "Stored" : "Synthesized",
                        systemImage: source == .stored ? "externaldrive.fill" : "wand.and.stars"
                    )
                    .font(.caption)
                    .foregroundStyle(source == .stored ? .blue : .orange)
                    if let age = viewModel.cacheAgeSecs {
                        Text("\(age)s ago")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
            }
            Spacer()
            if source == .stored {
                if isEditingPipeline || viewModel.hasEdits {
                    if viewModel.hasEdits {
                        Button("Save Changes") {
                            Task {
                                do {
                                    try await viewModel.savePricing(for: target)
                                    isEditingPipeline = false
                                    showSaveSuccess = true
                                } catch {
                                    saveError = "Could not save to operator. The operator may retain the former model. (\(error.localizedDescription))"
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.green)

                        Button("Forget Changes") {
                            viewModel.resetAllEdits()
                            isEditingPipeline = false
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                    } else {
                        Button("Done Editing") {
                            isEditingPipeline = false
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                } else {
                    Button {
                        isEditingPipeline = true
                    } label: {
                        Label("Edit Prices", systemImage: "pencil")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button {
                    showingReconcileConfirmation = true
                } label: {
                    Label("Reconcile", systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .alert("Reconcile Tools", isPresented: $showingReconcileConfirmation) {
                    Button("Cancel", role: .cancel) { }
                    Button("OK") {
                        reconciliationVM = ReconciliationViewModel()
                        showingReconciliation = true
                        Task {
                            if let url = try? await viewModel.resolveEndpoint(for: target),
                               let model = viewModel.pricingModel {
                                reconciliationVM.detectMismatch(
                                    endpointURL: url,
                                    storedModel: model,
                                    operatorSlug: viewModel.serviceVersions?["slug"]
                                )
                            }
                        }
                    }
                } message: {
                    Text("Reconcile compares your stored pricing model against the live MCP endpoint and suggests updates for new, changed, or removed tools.\n\nThe suggestions are advisory only — no changes are applied unless you choose to accept them.")
                }
            }
            Menu {
                Button {
                    viewModel.forceRefresh(for: target)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                if KeychainService.loadNsec(forNpub: target.npub) != nil {
                    Divider()
                    Button(role: .destructive) {
                        showingResetConfirm = true
                    } label: {
                        Label("Reset Pricing Model", systemImage: "arrow.counterclockwise")
                    }
                }
                if target is Operator {
                    Divider()
                    Button {
                        showingOnboardingSheet = true
                    } label: {
                        Label("Operator Credentials", systemImage: "key")
                    }
                    Button {
                        showingEditRegistration = true
                    } label: {
                        Label("Edit Registration", systemImage: "pencil")
                    }
                    Button {
                        showingAdoptionRequest = true
                    } label: {
                        Label(
                            (target as? Operator)?.authorityNpub == nil
                                ? "Request Registration"
                                : "Switch Authority…",
                            systemImage: "arrow.triangle.swap"
                        )
                    }
                    // Operator-support flow: paste a patron's invoice ID
                    // and re-trigger credit grant against BTCPay's
                    // authoritative settled state. Use when a patron
                    // escalates "I paid invoice XYZ, never got credits."
                    if target.mcpEndpointURL != nil {
                        Button {
                            showingRecoverPayment = true
                        } label: {
                            Label("Recover a Patron's Payment…", systemImage: "arrow.uturn.backward.circle")
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        showingDeregisterConfirm = true
                    } label: {
                        Label("Deregister Operator", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.subheadline)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .sheet(isPresented: $showingOnboardingSheet) {
                if target is Operator {
                    OnboardingStatusSheet(operator_: target as! Operator)
                }
            }
            .sheet(isPresented: $showingEditRegistration) {
                EditOperatorRegistrationSheet(operatorTarget: target)
            }
            .sheet(isPresented: $showingRecoverPayment) {
                if let endpointString = target.mcpEndpointURL,
                   let endpoint = URL(string: endpointString) {
                    // Operator-support recovery: operator signs proof
                    // (target IS the Operator, target.npub is the operator
                    // npub whose nsec must be in this device's Keychain).
                    // Patron npub is editable so the operator can paste it
                    // from a support escalation.
                    RecoverPaymentSheet(
                        operatorEndpoint: endpoint,
                        operatorName: target.displayName,
                        initialInvoiceId: "",
                        patronNpub: "",
                        patronNpubEditable: true,
                        operatorNpub: target.npub,
                        onSuccess: nil
                    )
                }
            }
            .confirmationDialog(
                "Deregister Operator",
                isPresented: $showingDeregisterConfirm,
                titleVisibility: .visible
            ) {
                Button("Deregister \(target.displayName)", role: .destructive) {
                    Task { await deregisterOperator() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This will remove the operator from the DPYC community registry. The operator will need to re-register with an Authority to resume service.")
            }
            .alert("Deregister Failed", isPresented: Binding(
                get: { deregisterError != nil },
                set: { if !$0 { deregisterError = nil } }
            )) {
                Button("OK") { deregisterError = nil }
            } message: {
                if let deregisterError { Text(deregisterError) }
            }
            .confirmationDialog(
                "Proof Required",
                isPresented: Binding(
                    get: { deregisterProofRemedy != nil },
                    set: { if !$0 { deregisterProofRemedy = nil } }
                ),
                titleVisibility: .visible,
                presenting: deregisterProofRemedy
            ) { remedy in
                if KeychainService.loadNsec(forNpub: remedy.signerNpub) != nil {
                    Button("Sign with Keychain & Retry") {
                        Task { await retryDeregisterWithProof(remedy) }
                    }
                }
                Button("Detach Locally Anyway", role: .destructive) {
                    Task { await detachOperatorLocallyOnly() }
                }
                Button("Cancel", role: .cancel) { }
            } message: { remedy in
                Text("The Authority requires \(remedy.kind == .operatorProof ? "the operator's" : "the Authority's") cryptographic consent (npub \(String(remedy.signerNpub.prefix(20)))…) before removing this registry entry. The nsec must be in this device's Keychain to auto-sign.")
            }
            .confirmationDialog(
                "Reset Pricing Model",
                isPresented: $showingResetConfirm,
                titleVisibility: .visible
            ) {
                Button("Reset to Defaults", role: .destructive) {
                    initializePricingModel(for: target)
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This erases the current pricing model and creates a fresh one with all tools at TBD (0 sats). You'll need to set prices for each paid tool before patrons can use them.")
            }
        }
    }

    private func errorContent(_ message: String) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48))
                    .foregroundStyle(.yellow)

                Text("Unable to Load")
                    .font(.title2.bold())

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)

                if let url = target.mcpEndpointURL, !url.isEmpty,
                   let link = URL(string: url) {
                    Link(url, destination: link)
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(.blue)
                }

                Text(target.npub)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)

                // Show onboarding checklist if available
                if target is Operator, target.mcpEndpointURL != nil {
                    if onboardingLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Checking configuration...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let status = onboardingStatus {
                        onboardingChecklist(status)
                    }

                }

            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if target is Operator, target.mcpEndpointURL != nil, onboardingStatus == nil {
                await loadOnboardingStatus()
            }
        }
    }

    @State private var showingAdoptionRequest = false
    @State private var showingSeekAdoption = false

    private var registeredNotConfiguredContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)

                Text("Registered")
                    .font(.title2.bold())

                Text("**\(target.displayName)** is registered in the DPYC community but needs configuration.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)

                if let url = target.mcpEndpointURL, !url.isEmpty,
                   let link = URL(string: url) {
                    Link(url, destination: link)
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(.blue)
                }

                Text(target.npub)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)

                // Live onboarding status
                if onboardingLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking configuration...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let status = onboardingStatus {
                    onboardingChecklist(status)
                } else {
                    // Fallback static checklist
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Operator is in the community registry", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Label("Checking operator configuration...", systemImage: "circle.dotted")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }


            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await loadOnboardingStatus()
        }
    }

    @ViewBuilder
    private func onboardingChecklist(_ status: MCPService.OnboardingStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Critical warning when vault/persistence is missing
            if status.vaultOk == false {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No Persistence")
                            .font(.subheadline.bold())
                            .foregroundStyle(.red)
                        Text("This operator has no database. It cannot persist credits, credentials, or any state. Re-register with the Authority to provision storage.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            Label("Operator is in the community registry", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.subheadline)

            ForEach(status.configured, id: \.field) { field in
                Label("\(fieldLabel(field.field))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)
            }

            if !status.missing.isEmpty {
                Divider()

                ForEach(status.missing, id: \.field) { field in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: categoryIcon(field.category))
                            .foregroundStyle(categoryColor(field.category))
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fieldLabel(field.field))
                                .font(.subheadline)
                                .foregroundStyle(categoryColor(field.category))
                            if let how = field.how {
                                Text(how)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

            }

            Divider()

            // Action chiclets — always visible
            HStack(spacing: 10) {
                Spacer()
                if status.missing.contains(where: { $0.category == "secret" }) {
                    Button {
                        if let endpoint = target.mcpEndpointURL,
                           let url = URL(string: endpoint) {
                            onRequestCourier?(CourierParams(
                                operatorName: target.displayName,
                                operatorNpub: target.npub,
                                endpointURL: url,
                                credentialService: onboardingStatus?.credentialService ?? "",
                                missingSecrets: status.missing
                                    .filter { $0.category == "secret" }
                                    .map { fieldLabel($0.field) },
                                greeting: onboardingStatus?.credentialGreeting ?? ""
                            ))
                        }
                    } label: {
                        Label("Deliver", systemImage: "lock.shield")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.orange)
                }

                Button {
                    Task { await loadOnboardingStatus() }
                } label: {
                    Label("Check", systemImage: "checkmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.blue)

                Button {
                    Task { await reattemptBootstrap() }
                } label: {
                    Label("Reattempt", systemImage: "square.and.pencil")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.indigo)
                Spacer()
            }

            if status.ready {
                Divider()
                Label("Operator is fully configured and ready to serve", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
            }
        }
    }


    private func fieldLabel(_ field: String) -> String {
        field.replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private func categoryIcon(_ category: String) -> String {
        switch category {
        case "authority": return "building.columns"
        case "secret": return "lock.shield"
        case "identity": return "key"
        default: return "circle"
        }
    }

    private func categoryColor(_ category: String) -> Color {
        switch category {
        case "authority": return .red
        case "secret": return .orange
        case "identity": return .purple
        default: return .secondary
        }
    }

    /// Reset pricing to a clean default — erases stale models and restores
    /// a fresh one with proper UUIDs from the tool registry.
    private func initializePricingModel(for target: any PricingTarget) {
        isInitializing = true
        Task {
            defer { isInitializing = false }
            guard let endpoint = target.mcpEndpointURL,
                  let endpointURL = URL(string: endpoint) else { return }
            do {
                _ = try await viewModel.resolveEndpoint(for: target)
                let service = MCPService()
                let proof = try await service.signRuntimeProof(
                    capability: "reset_pricing_model",
                    endpointURL: endpointURL,
                    operatorNpub: target.npub
                )
                // Single call: erase + restore default
                _ = try await service.callToolGeneric(
                    endpointURL: endpointURL,
                    toolName: "reset_pricing_model",
                    arguments: ["dpop_token": .string(proof)]
                )
                viewModel.forceRefresh(for: target)
            } catch {
                TrafficLogger.shared.log(.error, label: "Initialize Pricing", detail: error.localizedDescription)
                viewModel.retry(for: target)
            }
        }
    }

    private func loadOnboardingStatus() async {
        guard let endpoint = target.mcpEndpointURL,
              let endpointURL = URL(string: endpoint) else { return }

        onboardingLoading = true
        defer { onboardingLoading = false }

        do {
            _ = try await viewModel.resolveEndpoint(for: target)
            onboardingStatus = try await MCPService().callGetOnboardingStatus(
                endpointURL: endpointURL
            )
        } catch {
            // Silently fail — view falls back to static checklist
            TrafficLogger.shared.log(.error, label: "Onboarding Status", detail: error.localizedDescription)
        }
    }

    /// Force the operator to re-bootstrap (triggers service_status which
    /// exercises the vault/relay bootstrap path), then refresh onboarding.
    private func reattemptBootstrap() async {
        guard let endpoint = target.mcpEndpointURL,
              let endpointURL = URL(string: endpoint) else { return }

        onboardingLoading = true
        defer { onboardingLoading = false }

        do {
            _ = try await viewModel.resolveEndpoint(for: target)
            _ = try? await MCPService().callServiceStatus(
                endpointURL: endpointURL
            )
        } catch {
            TrafficLogger.shared.log(.error, label: "Reattempt Bootstrap", detail: error.localizedDescription)
        }

        await loadOnboardingStatus()
    }

    private var notRegisteredContent: some View {
        VStack(spacing: 24) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("Not Registered")
                .font(.title2.bold())

            Text("**\(target.displayName)** is not yet registered with the DPYC community. Select an Authority to register with.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            VStack(spacing: 4) {
                if let url = target.mcpEndpointURL, !url.isEmpty,
                   let link = URL(string: url) {
                    Link(url, destination: link)
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(.blue)
                } else {
                    Label("No MCP endpoint configured", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Text(target.npub)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }

            HStack(spacing: 12) {
                Button {
                    // Deferred courtship: the operator requests adoption and the
                    // chosen Authority's owner approves in their Pending Adoptions
                    // queue (distinct from the inline register_operator switch).
                    showingSeekAdoption = true
                } label: {
                    Label("Request Adoption", systemImage: "building.columns")
                }
                .buttonStyle(.borderedProminent)

                Button("Retry") {
                    viewModel.retry(for: target)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func deregisterOperator() async {
        guard let op = target as? Operator,
              let authNpub = op.authorityNpub else {
            // No authority link — just reset state
            viewModel.markNotRegistered()
            return
        }

        // Find the Authority's endpoint
        let authorities: [Authority] = (try? modelContext.fetch(FetchDescriptor<Authority>())) ?? []
        guard let authority = authorities.first(where: { $0.npub == authNpub }),
              let endpointString = authority.mcpEndpointURL,
              let endpointURL = URL(string: endpointString) else {
            // Can't reach Authority — just clear local link
            op.authorityNpub = nil
            try? modelContext.save()
            viewModel.markNotRegistered()
            return
        }

        let mcpService = MCPService()

        do {
            _ = try await mcpService.callDeregisterOperator(
                endpointURL: endpointURL,
                operatorNpub: op.npub,
                authorityNpub: authority.npub
            )
        } catch let MCPError.structuredError(code, _, extras) {
            // Proof-related rejections get a remedy dialog rather than a
            // dead-end "OK" alert. Local link is preserved so the user can
            // retry — otherwise an auto-clear would leave Authority and
            // local state inconsistent.
            switch code {
            case "authority_consent_required":
                deregisterProofRemedy = DeregisterProofRemedy(
                    kind: .authorityProof,
                    signerNpub: extras["authority_npub"] ?? authority.npub,
                    endpointURL: endpointURL,
                    operatorNpub: op.npub,
                    authorityNpub: authority.npub
                )
                return
            case "proof_required", "proof_invalid", "proof_refresh_needed":
                deregisterProofRemedy = DeregisterProofRemedy(
                    kind: .operatorProof,
                    signerNpub: op.npub,
                    endpointURL: endpointURL,
                    operatorNpub: op.npub,
                    authorityNpub: authority.npub
                )
                return
            default:
                deregisterError = "Registry removal failed: \(code). Local link cleared."
            }
        } catch {
            deregisterError = "Registry removal failed: \(error.localizedDescription). Local link cleared."
        }

        op.authorityNpub = nil
        try? modelContext.save()
        viewModel.markNotRegistered()
    }

    /// Retry deregister after the user opts to sign with Keychain.
    /// argsWithProof picks up the nsec automatically; the cached proof_token
    /// fallback also kicks in if a DM dance was completed elsewhere.
    private func retryDeregisterWithProof(_ remedy: DeregisterProofRemedy) async {
        guard let op = target as? Operator else { return }
        deregisterProofRemedy = nil
        let mcpService = MCPService()
        do {
            _ = try await mcpService.callDeregisterOperator(
                endpointURL: remedy.endpointURL,
                operatorNpub: remedy.operatorNpub,
                authorityNpub: remedy.authorityNpub
            )
            op.authorityNpub = nil
            try? modelContext.save()
            viewModel.markNotRegistered()
        } catch let MCPError.structuredError(code, _, _) {
            deregisterError = "Retry failed: \(code). The Authority still holds the registration; try again or detach locally."
        } catch {
            deregisterError = "Retry failed: \(error.localizedDescription)."
        }
    }

    /// "Detach Locally Anyway" — clear the local link without touching the
    /// Authority's registry. State will be inconsistent until the user
    /// re-runs deregister with proof or contacts the Authority operator.
    private func detachOperatorLocallyOnly() async {
        guard let op = target as? Operator else { return }
        deregisterProofRemedy = nil
        op.authorityNpub = nil
        try? modelContext.save()
        viewModel.markNotRegistered()
    }
}

/// Snapshot of an in-progress deregister awaiting a proof-signing decision.
struct DeregisterProofRemedy: Identifiable {
    enum Kind { case operatorProof, authorityProof }
    let id = UUID()
    let kind: Kind
    /// npub whose signature is needed (operator's or Authority's).
    let signerNpub: String
    let endpointURL: URL
    let operatorNpub: String
    let authorityNpub: String
}

// MARK: - Member Info Popover

struct MemberInfoButton: View {
    let member: MemberRecord
    @State private var showingInfo = false

    var body: some View {
        Button {
            showingInfo.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingInfo) {
            memberInfoContent
                .presentationCompactAdaptation(.popover)
        }
    }

    private var memberInfoContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(member.displayName)
                .font(.headline)

            if let notes = member.notes, !notes.isEmpty {
                Text(notes)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if let service = member.services?.first {
                Label(service.name, systemImage: "server.rack")
                    .font(.caption)
                if let desc = service.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let since = member.memberSince {
                Label("Member since \(since)", systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Label(member.role.capitalized, systemImage: "person.fill")
                Label(member.status.capitalized, systemImage: "circle.fill")
                    .foregroundStyle(member.status == "active" ? .green : .secondary)
            }
            .font(.caption)
        }
        .padding()
        .frame(idealWidth: 300)
    }
}

// MARK: - Service Versions Row

struct ServiceVersionsRow: View {
    let versions: [String: String]
    @State private var expanded = false

    /// The collapsed one-liner: slug + service version (e.g. "taxsort v0.22.0").
    private var primaryLabel: String? {
        guard let slug = versions["slug"], let version = versions["service"] else { return nil }
        return "\(slug) v\(version)"
    }

    /// Detail rows exclude slug and service (already shown in the primary label).
    private var detailVersions: [(key: String, value: String)] {
        let exclude: Set = ["slug", "service"]
        let priority = ["tollbooth_dpyc", "git_commit", "repo"]
        return versions
            .filter { !exclude.contains($0.key) }
            .sorted { a, b in
                let ai = priority.firstIndex(of: a.key) ?? priority.count
                let bi = priority.firstIndex(of: b.key) ?? priority.count
                return ai < bi
            }
    }

    var body: some View {
        if let label = primaryLabel {
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "shippingbox")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(label)
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(detailVersions, id: \.key) { entry in
                        HStack(spacing: 6) {
                            Text(formatName(entry.key))
                                .frame(width: 120, alignment: .trailing)
                                .foregroundStyle(.secondary)
                            Text(entry.value)
                                .monospaced()
                        }
                        .font(.caption2)
                    }
                }
                .padding(.leading, 20)
            }
        }
    }

    private func formatName(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
    }
}
