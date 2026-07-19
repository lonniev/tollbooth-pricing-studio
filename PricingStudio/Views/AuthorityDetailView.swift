import SwiftUI
import SwiftData

struct AuthorityDetailView: View {
    let authority: Authority
    @Bindable var pricingVM: PricingViewModel
    var authorityVM: AuthorityCollectionViewModel?
    var onOperatorSelected: ((Operator) -> Void)?
    var onRequestCourier: ((CourierParams) -> Void)?
    @State private var balanceVM = AuthorityBalanceViewModel()
    @State private var showingTopOff = false
    @State private var fundingOperator: Operator?
    @State private var movingOperator: Operator?
    @State private var onboardingStatus: MCPService.OnboardingStatus?
    @State private var loadingOnboarding = false
    @State private var showingForgetConfirm = false
    @State private var showingProfile = false
    @State private var forgetState: ForgetState = .idle
    @State private var adoptionsVM = PendingAdoptionsViewModel()
    @State private var rejectingRequest: MCPService.AdoptionRequest?
    @State private var rejectReason = ""
    @State private var booksHealth: MCPService.NeonBooksHealth?
    @State private var booksHealthError: String?
    @State private var loadingBooksHealth = false
    @Query private var allAuthorities: [Authority]
    @Query private var allOperators: [Operator]
    @Environment(\.modelContext) private var modelContext

    private enum ForgetState {
        case idle, forgetting, done(String), error(String)
    }

    private var isLinked: Bool {
        KeychainService.loadNsec(forNpub: authority.npub) != nil
    }

    /// Where this Authority's *certification* balance lives — the api_sats it
    /// spends to `certify_sats` its children's purchases. For a standard
    /// (certified) Authority that's its **parent**; for a penultimate one
    /// (self-funding, parent is Prime) that's **itself**. The economic model
    /// is uniform: you replenish your certification capacity wherever you pay
    /// for it. `nil` only when the source isn't resolvable (e.g. parent not in
    /// the roster yet), in which case we fall back to the Authority itself.
    private var certificationSource: InvoiceSource {
        authority.asRole()
            .invoiceSources(authorities: allAuthorities, operators: allOperators)
            .first
            ?? authority.asInvoiceSource
    }

    /// True when the certification balance lives upstream (a standard
    /// Authority paying its parent), false when self-funding (penultimate).
    private var replenishesUpstream: Bool {
        certificationSource.npub != authority.npub
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                authorityHeader
                Divider()
                // Show the claim button whenever there's an MCP endpoint —
                // both for first-time nsec linking (!isLinked) and for the
                // upstream challenge-response dance against a parent
                // Authority (isLinked but never claimed against parent).
                // The two operations share the same sheet but are
                // semantically distinct.
                claimAuthorityButton
                if authority.mcpEndpointURL != nil {
                    Divider()
                    authorityBalanceSection
                    Divider()
                    operatorCredentialSection
                    Divider()
                    pendingAdoptionsSection
                    Divider()
                    networkBooksHealthSection
                }
                Divider()
                connectedOperatorsSection
            }
        }
        // navigationTitle removed — shared entityHeader provides the name
        .alert(
            "Reject adoption request?",
            isPresented: Binding(
                get: { rejectingRequest != nil },
                set: { if !$0 { rejectingRequest = nil } }
            ),
            presenting: rejectingRequest
        ) { req in
            TextField("Reason (optional)", text: $rejectReason)
            Button("Reject", role: .destructive) {
                rejectingRequest = nil
                let reason = rejectReason
                rejectReason = ""
                Task {
                    await adoptionsVM.decide(
                        .reject(reason: reason),
                        on: req,
                        authority: authority,
                        context: modelContext
                    )
                }
            }
            Button("Cancel", role: .cancel) {
                rejectingRequest = nil
                rejectReason = ""
            }
        } message: { _ in
            Text("The operator will see this request as rejected. A reason is optional.")
        }
        .sheet(isPresented: Binding(
            get: { authorityVM?.showingAdoptSheet ?? false },
            set: { authorityVM?.showingAdoptSheet = $0 }
        )) {
            AdoptOperatorSheet(
                authority: authority,
                authorityVM: authorityVM!,
                pricingVM: pricingVM
            )
        }
        .sheet(isPresented: $showingProfile) {
            EditNostrProfileSheet(npub: authority.npub, initialDisplayName: authority.displayName)
        }
        .sheet(isPresented: $showingTopOff) {
            // Replenish this Authority's certification capacity at the place it
            // actually pays for it: its parent (standard) or itself
            // (penultimate). Cashier = the source; beneficiary = this Authority.
            if let endpoint = certificationSource.mcpEndpointURL {
                PurchaseCreditsSheet(
                    cashierName: certificationSource.displayName,
                    cashierNpub: certificationSource.npub,
                    endpoint: endpoint,
                    purchaserNpub: authority.npub,
                    beneficiaryDisplayName: authority.displayName,
                    beneficiaryBadge: .authority,
                    cashierBadge: .authority,
                    presets: [500, 1000, 5000, 10000],
                    onSettled: {
                        Task {
                            await balanceVM.loadCertificationBalance(
                                authorityNpub: authority.npub, source: certificationSource
                            )
                        }
                    }
                )
            }
        }
        .sheet(item: $fundingOperator) { op in
            if let endpoint = authority.mcpEndpointURL {
                PurchaseCreditsSheet(
                    cashierName: authority.displayName,
                    cashierNpub: authority.npub,
                    endpoint: endpoint,
                    purchaserNpub: op.npub,
                    beneficiaryDisplayName: op.displayName,
                    beneficiaryBadge: .operator,
                    cashierBadge: .authority,
                    presets: [500, 1000, 5000, 10000]
                )
            }
        }
        .sheet(item: $movingOperator) { op in
            RegisterOperatorSheet(operatorTarget: op, pricingVM: pricingVM)
        }
    }

    // MARK: - Claim Authority

    @ViewBuilder
    private var claimAuthorityButton: some View {
        if authority.mcpEndpointURL != nil, let vm = authorityVM {
            Button {
                vm.requestClaim(authority)
            } label: {
                Label(
                    isLinked ? "Claim with Parent" : "Link & Claim",
                    systemImage: isLinked ? "link.badge.plus" : "person.badge.key.fill"
                )
                .font(.caption)
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
            .controlSize(.small)
        }
    }

    // MARK: - Header

    private var authorityHeader: some View {
        HStack(spacing: 8) {
            Text(authority.npub)
                .font(.caption)
                .monospaced()
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if authority.isAutoDiscovered {
                Label("Auto-discovered", systemImage: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if isLinked {
                Label("Identity Linked", systemImage: "checkmark.seal.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                Button {
                    showingProfile = true
                } label: {
                    Image(systemName: "person.text.rectangle")
                }
                .font(.caption2)
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: - Authority Balance

    @ViewBuilder
    private var authorityBalanceSection: some View {
        ParentAccountCard(
            parentDisplayName: certificationSource.displayName,
            balance: balanceVM.balanceState,
            selfFunded: authority.isPenultimate,
            feeExplanation: "spent as the certification fee each time you sell",
            isReconciling: balanceVM.isReconciling,
            reconcileResult: balanceVM.reconcileResult,
            onTopUp: { showingTopOff = true },
            onReconcile: {
                guard case .loaded(let result) = balanceVM.balanceState else { return }
                Task {
                    await balanceVM.reconcileCertification(
                        authorityNpub: authority.npub,
                        source: certificationSource,
                        pendingIds: result.pendingInvoiceIds
                    )
                }
            },
            onRefresh: {
                Task {
                    await balanceVM.loadCertificationBalance(
                        authorityNpub: authority.npub, source: certificationSource
                    )
                }
            }
        )
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Operator Credential Section

    @ViewBuilder
    private var operatorCredentialSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: onboardingStatus?.ready == true ? "checkmark.shield.fill" : "shield.slash")
                    .foregroundStyle(onboardingStatus?.ready == true ? .green : .secondary)
                Text("Operator Secrets")
                    .font(.caption.bold())
                Spacer()
                if loadingOnboarding {
                    ProgressView().controlSize(.mini)
                }
            }

            if let status = onboardingStatus {
                ForEach(status.configured, id: \.field) { field in
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                        Text(fieldLabel(field.field))
                            .font(.caption2)
                    }
                }

                ForEach(status.missing, id: \.field) { field in
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Text(fieldLabel(field.field))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                ForEach(status.optionalMissing, id: \.field) { field in
                    HStack(spacing: 4) {
                        Image(systemName: "circle.dashed")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(fieldLabel(field.field)) (optional)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 8) {
                if onboardingStatus == nil && !loadingOnboarding {
                    Button {
                        Task { await loadAuthorityOnboardingStatus() }
                    } label: {
                        Label("Check", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                let hasMissing = !(onboardingStatus?.missing.isEmpty ?? true)
                    || !(onboardingStatus?.optionalMissing.isEmpty ?? true)
                if hasMissing, let onRequestCourier,
                   let endpoint = authority.mcpEndpointURL,
                   let url = URL(string: endpoint),
                   let status = onboardingStatus {
                    Button {
                        onRequestCourier(CourierParams(
                            operatorName: authority.displayName,
                            operatorNpub: authority.npub,
                            endpointURL: url,
                            credentialService: status.credentialService ?? "",
                            missingSecrets: (status.missing + status.optionalMissing)
                                .filter { $0.category == "secret" }
                                .map { fieldLabel($0.field) }
                        ))
                    } label: {
                        Label("Deliver", systemImage: "lock.shield")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.orange)
                }

                if onboardingStatus != nil {
                    Button(role: .destructive) {
                        showingForgetConfirm = true
                    } label: {
                        Label("Forget", systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            switch forgetState {
            case .idle: EmptyView()
            case .forgetting:
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Forgetting\u{2026}").font(.caption2).foregroundStyle(.secondary)
                }
            case .done(let msg):
                Label(msg, systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
            case .error(let msg):
                Label(msg, systemImage: "xmark.circle.fill").font(.caption2).foregroundStyle(.red)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .task(id: authority.npub) {
            onboardingStatus = nil
            balanceVM = AuthorityBalanceViewModel()
            forgetState = .idle
            await loadAuthorityOnboardingStatus()
        }
        .confirmationDialog("Forget Credentials", isPresented: $showingForgetConfirm, titleVisibility: .visible) {
            Button("Forget operator credentials", role: .destructive) {
                Task { await forgetAuthorityCredentials() }
            }
        } message: {
            Text("This removes the vaulted credentials. Re-deliver via Secure Courier to restore.")
        }
    }

    // MARK: - Credential Helpers

    private func loadAuthorityOnboardingStatus() async {
        guard let endpoint = authority.mcpEndpointURL,
              let endpointURL = URL(string: endpoint) else { return }
        loadingOnboarding = true
        do {
            onboardingStatus = try await MCPService().callGetOnboardingStatus(endpointURL: endpointURL)
        } catch {
            // Non-fatal — credential section just won't show field details
        }
        loadingOnboarding = false
    }

    private func forgetAuthorityCredentials() async {
        let svc = onboardingStatus?.credentialService ?? ""
        guard !svc.isEmpty,
              let endpoint = authority.mcpEndpointURL,
              let endpointURL = URL(string: endpoint) else {
            forgetState = .error("No credential service or endpoint")
            return
        }
        forgetState = .forgetting
        do {
            _ = try await MCPService().callForgetCredentials(
                endpointURL: endpointURL, service: svc, npub: authority.npub
            )
            forgetState = .done("Credentials forgotten. Re-deliver via Secure Courier.")
            await loadAuthorityOnboardingStatus()
        } catch {
            forgetState = .error(error.localizedDescription)
        }
    }

    private func fieldLabel(_ field: String) -> String {
        field.replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    // MARK: - Pending Adoptions (deferred-courtship owner queue)

    @ViewBuilder
    private var pendingAdoptionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Pending Adoptions", systemImage: "person.crop.circle.badge.questionmark")
                    .font(.headline)
                if adoptionsVM.pendingCount > 0 {
                    Text("\(adoptionsVM.pendingCount)")
                        .font(.caption.bold())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.orange.opacity(0.2)))
                }
                Spacer()
                if isLinked {
                    Button {
                        Task { await reloadAdoptions() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }

            switch adoptionsVM.state {
            case .idle:
                if !isLinked {
                    Text("Link this Authority’s identity to review adoption requests.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading requests…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .loaded(let rows):
                if rows.isEmpty {
                    Text("No pending requests.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { req in
                        adoptionRow(req)
                        if req.id != rows.last?.id { Divider() }
                    }
                }
            case .error(let msg):
                VStack(alignment: .leading, spacing: 6) {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    if isLinked {
                        Button("Retry") { Task { await reloadAdoptions() } }
                            .font(.caption)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .task(id: authority.npub) {
            if isLinked, authority.mcpEndpointURL != nil {
                await reloadAdoptions()
            }
        }
    }

    @ViewBuilder
    private func adoptionRow(_ req: MCPService.AdoptionRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(req.operatorNpub)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            if !req.serviceURL.isEmpty {
                Text(req.serviceURL)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !req.note.isEmpty {
                Text(req.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            let timing = adoptionTimingText(req)
            if !timing.isEmpty {
                Text(timing)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            switch adoptionsVM.decisionStatus[req.operatorNpub] {
            case .none:
                adoptionActions(req)
            case .deciding:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Working…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .needsAuthorityProof(let npub):
                ProofConsentSection(
                    kind: "Authority",
                    npub: npub,
                    explanation: "Approving provisions this operator. The wheel needs cryptographic proof that you hold this Authority’s nsec.",
                    phase: nil,
                    onAcquire: { await adoptionsVM.acquireProofAndRetry(on: req, authority: authority, context: modelContext) },
                    onVerify: { await adoptionsVM.verifyProofAndRetry(on: req, authority: authority, context: modelContext) }
                )
            case .acquiringProof(let npub, let phase):
                ProofConsentSection(
                    kind: "Authority",
                    npub: npub,
                    explanation: "",
                    phase: phase,
                    onAcquire: { await adoptionsVM.acquireProofAndRetry(on: req, authority: authority, context: modelContext) },
                    onVerify: { await adoptionsVM.verifyProofAndRetry(on: req, authority: authority, context: modelContext) }
                )
            case .failed(let msg):
                VStack(alignment: .leading, spacing: 4) {
                    Label(msg, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                    adoptionActions(req)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func adoptionActions(_ req: MCPService.AdoptionRequest) -> some View {
        HStack(spacing: 10) {
            Button {
                Task { await adoptionsVM.decide(.approve, on: req, authority: authority, context: modelContext) }
            } label: {
                // Label strips the glyph under .borderedProminent — use HStack.
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill")
                    Text("Approve")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.small)

            Button(role: .destructive) {
                rejectReason = ""
                rejectingRequest = req
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "xmark")
                    Text("Reject")
                }
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.small)
        }
    }

    private func reloadAdoptions() async {
        guard let endpoint = authority.mcpEndpointURL,
              let url = URL(string: endpoint) else { return }
        await adoptionsVM.load(endpointURL: url, authorityNpub: authority.npub)
    }

    /// "requested 2026-06-17 11:29 · expires 2026-06-24 11:29". Trimmed to
    /// minute precision and tolerant of both `T` and space separators —
    /// deliberately not relative-formatted to avoid misparsing the wheel's
    /// Postgres TIMESTAMPTZ strings into nonsense intervals.
    private func adoptionTimingText(_ req: MCPService.AdoptionRequest) -> String {
        var parts: [String] = []
        if !req.requestedAt.isEmpty { parts.append("requested \(shortStamp(req.requestedAt))") }
        if !req.expiresAt.isEmpty { parts.append("expires \(shortStamp(req.expiresAt))") }
        return parts.joined(separator: " · ")
    }

    private func shortStamp(_ s: String) -> String {
        String(s.replacingOccurrences(of: "T", with: " ").prefix(16))
    }

    // MARK: - Network Books Health (Neon/Postgres steward view)

    @ViewBuilder
    private var networkBooksHealthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Network Books Health", systemImage: "cylinder.split.1x2")
                    .font(.headline)
                if let health = booksHealth {
                    Circle()
                        .fill(healthColor(health.overallStatus))
                        .frame(width: 10, height: 10)
                        .accessibilityLabel("Overall status \(health.overallStatus)")
                }
                Spacer()
                if loadingBooksHealth {
                    ProgressView().controlSize(.small)
                } else if isLinked {
                    Button {
                        Task { await loadBooksHealth() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }

            if !isLinked {
                Text("Link this Authority’s identity to read database health.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let msg = booksHealthError {
                VStack(alignment: .leading, spacing: 6) {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Retry") { Task { await loadBooksHealth() } }
                        .font(.caption)
                }
            } else if let health = booksHealth {
                booksHealthBody(health)
            } else if !loadingBooksHealth {
                Text("No reading yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .task(id: authority.npub) {
            booksHealth = nil
            booksHealthError = nil
            if isLinked, authority.mcpEndpointURL != nil {
                await loadBooksHealth()
            }
        }
    }

    @ViewBuilder
    private func booksHealthBody(_ health: MCPService.NeonBooksHealth) -> some View {
        // Own books 402-locked — loud, this Authority can't certify.
        if health.ownBooks.status == "quota_exceeded" {
            Label("This Authority’s own books are 402-locked.", systemImage: "lock.fill")
                .font(.caption.bold())
                .foregroundStyle(.red)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(.red.opacity(0.12)))
        } else if health.ownBooks.status != "ok" && health.ownBooks.status != "unknown" {
            Label(
                health.ownBooks.detail.isEmpty
                    ? "Own books: \(health.ownBooks.status)"
                    : health.ownBooks.detail,
                systemImage: "exclamationmark.circle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }

        // Neon control-plane block.
        if health.neonApi.configured == false {
            Label(
                health.neonApi.hint ?? "Proactive Neon monitoring isn’t enabled yet.",
                systemImage: "gauge.badge.minus"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        } else if let err = health.neonApi.error {
            Label(err, systemImage: "externaldrive.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.red)
        } else if health.neonApi.projects.isEmpty {
            Text("No Neon projects reported.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(health.neonApi.projects) { project in
                neonProjectRow(project)
            }
        }

        // Operators that reported a 402.
        if !health.operatorAlerts.isEmpty {
            Divider().padding(.vertical, 2)
            Text("Operators reporting 402 (\(health.operatorAlertCount))")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            ForEach(health.operatorAlerts) { alert in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(shortNpub(alert.operatorNpub))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Text("402 · last seen \(relativeStamp(alert.lastSeenAt))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func neonProjectRow(_ project: MCPService.NeonProjectUsage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name.isEmpty ? project.projectId : project.name)
                    .font(.caption.bold())
                Text("\(pctText(project.usedPct))% of \(hoursText(project.allowanceHours))h · resets \(shortStamp(project.quotaResetAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Text(projectChipLabel(project.status))
                .font(.caption2.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(healthColor(project.status).opacity(0.18)))
                .foregroundStyle(healthColor(project.status))
        }
        .padding(.vertical, 2)
    }

    // MARK: - Books Health helpers

    /// Green ok / amber warning / red critical|exhausted|quota_exceeded /
    /// grey unknown — the app's existing status-color idiom.
    private func healthColor(_ status: String) -> Color {
        switch status {
        case "ok": return .green
        case "warning": return .orange
        case "critical", "exhausted", "quota_exceeded", "error", "unreachable": return .red
        default: return .secondary
        }
    }

    private func projectChipLabel(_ status: String) -> String {
        switch status {
        case "exhausted": return "402 — quota exhausted"
        case "critical": return "critical"
        case "warning": return "warning"
        case "ok": return "ok"
        default: return status.isEmpty ? "unknown" : status
        }
    }

    private func pctText(_ pct: Double) -> String {
        String(format: "%.0f", pct)
    }

    private func hoursText(_ hours: Double) -> String {
        // Whole-number allowances read cleaner without a trailing ".0".
        hours == hours.rounded()
            ? String(format: "%.0f", hours)
            : String(format: "%.1f", hours)
    }

    private func shortNpub(_ npub: String) -> String {
        npub.count > 20 ? "\(npub.prefix(16))…\(npub.suffix(4))" : npub
    }

    /// Relative "last seen" for the ISO-8601 alert timestamps (e.g. "30 min
    /// ago"). Falls back to a trimmed stamp when the string doesn't parse.
    private func relativeStamp(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unknown" }
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let date = isoFrac.date(from: trimmed) ?? iso.date(from: trimmed)
        guard let date else { return shortStamp(s) }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: date, relativeTo: Date())
    }

    private func loadBooksHealth() async {
        guard let endpoint = authority.mcpEndpointURL,
              let url = URL(string: endpoint) else { return }
        loadingBooksHealth = true
        booksHealthError = nil
        do {
            booksHealth = try await MCPService().callNetworkBooksHealth(
                endpointURL: url, authorityNpub: authority.npub
            )
        } catch let MCPError.structuredError(code, message, _) {
            booksHealth = nil
            booksHealthError = message.isEmpty ? code : message
        } catch {
            booksHealth = nil
            booksHealthError = error.localizedDescription
        }
        loadingBooksHealth = false
    }

    // MARK: - Connected Operators

    private var connectedOperatorsSection: some View {
        ConnectedOperatorsList(
            authorityNpub: authority.npub,
            authorityEndpointURL: authority.mcpEndpointURL,
            onOperatorSelected: onOperatorSelected,
            onFundOperator: { op in fundingOperator = op },
            onMoveOperator: { op in movingOperator = op },
            onAdopt: authority.mcpEndpointURL != nil && authorityVM != nil
                ? { authorityVM?.requestAdopt(authority) }
                : nil
        )
    }

    // Pricing is now a separate tab in the Authority View picker.
}

// MARK: - Connected Operators List

/// Shows operators whose authorityNpub matches this authority.
private struct ConnectedOperatorsList: View {
    let authorityNpub: String
    let authorityEndpointURL: String?
    var onOperatorSelected: ((Operator) -> Void)?
    var onFundOperator: ((Operator) -> Void)?
    var onMoveOperator: ((Operator) -> Void)?
    var onAdopt: (() -> Void)?
    @Query private var allOperators: [Operator]
    @Query private var allAuthorities: [Authority]
    @Environment(\.modelContext) private var modelContext
    @State private var deregisterError: String?
    @State private var deregisterProofRemedy: DeregisterProofRemedy?
    @State private var operatorBalances: [String: Int] = [:]  // npub → balance

    init(authorityNpub: String, authorityEndpointURL: String? = nil, onOperatorSelected: ((Operator) -> Void)? = nil, onFundOperator: ((Operator) -> Void)? = nil, onMoveOperator: ((Operator) -> Void)? = nil, onAdopt: (() -> Void)? = nil) {
        self.authorityNpub = authorityNpub
        self.authorityEndpointURL = authorityEndpointURL
        self.onOperatorSelected = onOperatorSelected
        self.onFundOperator = onFundOperator
        self.onMoveOperator = onMoveOperator
        self.onAdopt = onAdopt
        self._allOperators = Query(sort: \Operator.addedAt)
        self._allAuthorities = Query()
    }

    /// Operators registered DIRECTLY with this Authority. Their fee ledger
    /// lives at this Authority's MCP, so balances are fetchable from
    /// authorityEndpointURL.
    private var directOperators: [Operator] {
        allOperators.filter { $0.authorityNpub == authorityNpub }
    }

    /// Immediate child Authorities — those whose parentAuthorityNpub points
    /// at this one. Each child Authority is also an Operator at THIS
    /// Authority (where its fee ledger lives), so they get rendered as
    /// Operator-tiles in the same row.
    private var childAuthoritiesAsOperators: [Authority] {
        allAuthorities.filter { $0.parentAuthorityNpub == authorityNpub }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Connected Operators")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                if let onAdopt {
                    Button {
                        onAdopt()
                    } label: {
                        Label("Adopt Operator", systemImage: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            if directOperators.isEmpty && childAuthoritiesAsOperators.isEmpty {
                Text("No connected operators")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(directOperators) { op in
                            Button {
                                onOperatorSelected?(op)
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: "server.rack")
                                        .font(.title3)
                                        .foregroundStyle(.orange)
                                    Text(op.displayName)
                                        .font(.caption2)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if let bal = operatorBalances[op.npub] {
                                        Text("\(bal) sats")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(bal < 50 ? .red : .green)
                                    }
                                }
                                .frame(width: 80)
                                .padding(.vertical, 6)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if let onFundOperator {
                                    Button {
                                        onFundOperator(op)
                                    } label: {
                                        Label("Fund Operator", systemImage: "bolt.fill")
                                    }
                                }
                                if let onMoveOperator {
                                    Button {
                                        onMoveOperator(op)
                                    } label: {
                                        Label("Move to Different Authority…", systemImage: "arrow.triangle.swap")
                                    }
                                }
                                Button(role: .destructive) {
                                    Task { await deregisterOperator(op) }
                                } label: {
                                    Label("Disconnect from Authority", systemImage: "minus.circle")
                                }
                            }
                        }
                        // Each child Authority IS an Operator vis-a-vis THIS
                        // Authority — its fee ledger lives here, so it shows
                        // up in the Connected Operators row alongside ordinary
                        // operators. Distinguishing icon (Authority columns)
                        // and a dashed border signal "this is a child
                        // Authority, not a plain Operator." No context menu:
                        // any mutation belongs to the Authority management
                        // surface, not the Operator-side disconnect/move.
                        ForEach(childAuthoritiesAsOperators) { childAuth in
                            VStack(spacing: 4) {
                                Image(systemName: "building.columns")
                                    .font(.title3)
                                    .foregroundStyle(.purple)
                                Text(childAuth.displayName)
                                    .font(.caption2)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if let bal = operatorBalances[childAuth.npub] {
                                    Text("\(bal) sats")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(bal < 50 ? .red : .green)
                                }
                                Text("Authority")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(width: 80)
                            .padding(.vertical, 6)
                            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(.purple.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            )
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 8)
                .task(id: authorityNpub) { await loadOperatorBalances() }
            }
        }
        .alert("Disconnect Failed", isPresented: Binding(
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
                Task { await detachOperatorLocallyOnly(remedy) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { remedy in
            Text("The Authority requires \(remedy.kind == .operatorProof ? "the operator's" : "the Authority's") cryptographic consent (npub \(String(remedy.signerNpub.prefix(20)))…) before removing this registry entry. The nsec must be in this device's Keychain to auto-sign.")
        }
    }

    private func loadOperatorBalances() async {
        guard let endpointString = authorityEndpointURL,
              let endpointURL = URL(string: endpointString) else { return }
        let mcpService = MCPService()

        // Direct operators and child Authorities-as-Operators both pay
        // their fees to THIS Authority, so both ledgers live at the same
        // endpoint. One loop covers both sets.
        let patronNpubs = directOperators.map(\.npub)
            + childAuthoritiesAsOperators.map(\.npub)

        for npub in patronNpubs {
            do {
                let result = try await mcpService.callCheckBalance(
                    endpointURL: endpointURL,
                    patronNpub: npub
                )
                operatorBalances[npub] = result.balanceApiSats
            } catch {
                // Silently skip — balance display is optional
            }
        }
    }

    private func deregisterOperator(_ op: Operator) async {
        guard let endpointString = authorityEndpointURL,
              let endpointURL = URL(string: endpointString) else {
            // No Authority endpoint — just clear local link
            op.authorityNpub = nil
            try? modelContext.save()
            return
        }

        let mcpService = MCPService()

        do {
            _ = try await mcpService.callDeregisterOperator(
                endpointURL: endpointURL,
                operatorNpub: op.npub,
                authorityNpub: authorityNpub
            )
        } catch let MCPError.structuredError(code, _, extras) {
            // Same proof-remedy fork as PricingDetailView: preserve local
            // link so the user can retry instead of auto-clearing into an
            // inconsistent state.
            switch code {
            case "authority_consent_required":
                deregisterProofRemedy = DeregisterProofRemedy(
                    kind: .authorityProof,
                    signerNpub: extras["authority_npub"] ?? authorityNpub,
                    endpointURL: endpointURL,
                    operatorNpub: op.npub,
                    authorityNpub: authorityNpub
                )
                return
            case "proof_required", "proof_invalid", "proof_refresh_needed":
                deregisterProofRemedy = DeregisterProofRemedy(
                    kind: .operatorProof,
                    signerNpub: op.npub,
                    endpointURL: endpointURL,
                    operatorNpub: op.npub,
                    authorityNpub: authorityNpub
                )
                return
            default:
                deregisterError = "Registry removal failed: \(code). Local link cleared."
            }
        } catch {
            // Log but don't block — still clear the local link
            deregisterError = "Registry removal failed: \(error.localizedDescription). Local link cleared."
        }

        // Always clear local authority link
        op.authorityNpub = nil
        try? modelContext.save()
    }

    private func retryDeregisterWithProof(_ remedy: DeregisterProofRemedy) async {
        deregisterProofRemedy = nil
        guard let op = allOperators.first(where: { $0.npub == remedy.operatorNpub }) else { return }
        let mcpService = MCPService()
        do {
            _ = try await mcpService.callDeregisterOperator(
                endpointURL: remedy.endpointURL,
                operatorNpub: remedy.operatorNpub,
                authorityNpub: remedy.authorityNpub
            )
            op.authorityNpub = nil
            try? modelContext.save()
        } catch let MCPError.structuredError(code, _, _) {
            deregisterError = "Retry failed: \(code). The Authority still holds the registration; try again or detach locally."
        } catch {
            deregisterError = "Retry failed: \(error.localizedDescription)."
        }
    }

    private func detachOperatorLocallyOnly(_ remedy: DeregisterProofRemedy) async {
        deregisterProofRemedy = nil
        guard let op = allOperators.first(where: { $0.npub == remedy.operatorNpub }) else { return }
        op.authorityNpub = nil
        try? modelContext.save()
    }
}

// MARK: - Adopt Operator Sheet

private struct AdoptOperatorSheet: View {
    let authority: Authority
    @Bindable var authorityVM: AuthorityCollectionViewModel
    @Bindable var pricingVM: PricingViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Operator.addedAt) private var allOperators: [Operator]
    @State private var selectedOperator: Operator?

    /// Operators not yet linked to any authority.
    private var unclaimedOperators: [Operator] {
        allOperators.filter { $0.authorityNpub == nil }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if unclaimedOperators.isEmpty {
                        Text("All operators are already claimed.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Operator", selection: $selectedOperator) {
                            Text("Select an operator…").tag(nil as Operator?)
                            ForEach(unclaimedOperators) { op in
                                Text(op.displayName).tag(op as Operator?)
                            }
                        }
                    }
                } header: {
                    Text("Choose an unclaimed operator to register with \(authority.displayName)")
                }

                if case .registering = authorityVM.adoptionStatus {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Registering operator…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if case .success(let message) = authorityVM.adoptionStatus {
                    Section {
                        Label("Registration successful", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if case .failed(let error) = authorityVM.adoptionStatus {
                    Section {
                        Label("Registration failed", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // --- Proof acquisition flow ----------------------------------
                // When the Authority's wheel reports a missing/invalid proof
                // for either side, surface a remedy path instead of dead-ending.
                // Shared with the Pending Adoptions queue via ProofConsentSection.
                if case .needsAuthorityProof(let npub) = authorityVM.adoptionStatus {
                    Section {
                        ProofConsentSection(
                            kind: "Authority",
                            npub: npub,
                            explanation: "The Authority’s wheel needs cryptographic proof that you hold the Authority’s nsec before it will adopt this operator.",
                            phase: nil,
                            onAcquire: { await retryAcquire(npub: npub) },
                            onVerify: { await retryVerify(npub: npub) }
                        )
                    } header: {
                        Text("Proof needed to continue")
                    }
                }

                if case .needsOperatorProof(let npub) = authorityVM.adoptionStatus {
                    Section {
                        ProofConsentSection(
                            kind: "Operator",
                            npub: npub,
                            explanation: "The Authority’s wheel needs cryptographic proof that you hold the operator’s nsec.",
                            phase: nil,
                            onAcquire: { await retryAcquire(npub: npub) },
                            onVerify: { await retryVerify(npub: npub) }
                        )
                    } header: {
                        Text("Proof needed to continue")
                    }
                }

                if case .acquiringProof(let npub, let phase) = authorityVM.adoptionStatus {
                    Section {
                        ProofConsentSection(
                            kind: "Authority",
                            npub: npub,
                            explanation: "",
                            phase: phase,
                            onAcquire: { await retryAcquire(npub: npub) },
                            onVerify: { await retryVerify(npub: npub) }
                        )
                    } header: {
                        Text("Acquiring proof")
                    }
                }
            }
            .navigationTitle("Adopt Operator")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Adopt") {
                        guard let op = selectedOperator else { return }
                        Task {
                            await authorityVM.adoptOperator(
                                authority: authority,
                                operatorToAdopt: op,
                                context: modelContext
                            )
                        }
                    }
                    .disabled(selectedOperator == nil || isAdoptionInFlight)
                }
            }
        }
    }

    /// True when the adoption flow is mid-call (registering, sending the
    /// proof challenge, or verifying the reply). The Adopt button is
    /// disabled in any of these states.
    private var isAdoptionInFlight: Bool {
        switch authorityVM.adoptionStatus {
        case .registering, .acquiringProof:
            return true
        default:
            return false
        }
    }

    /// Retry closures injected into the shared `ProofConsentSection`. They
    /// capture the currently-selected operator and drive the adopt VM's
    /// reused npub-proof handshake.
    private func retryAcquire(npub: String) async {
        guard let op = selectedOperator else { return }
        await authorityVM.acquireProofAndRetryAdopt(
            for: npub,
            authority: authority,
            operatorToAdopt: op,
            context: modelContext
        )
    }

    private func retryVerify(npub: String) async {
        guard let op = selectedOperator else { return }
        await authorityVM.verifyProofAndRetryAdopt(
            for: npub,
            authority: authority,
            operatorToAdopt: op,
            context: modelContext
        )
    }
}


// MARK: - Edit Nostr Profile (kind-0)

/// Edit and publish the holder's Nostr kind-0 profile (name, about, avatar URL).
/// Studio signs with the identity's Keychain nsec and publishes to relays — the
/// profile is self-sovereign and shows up in every Nostr client.
///
/// Used by Authorities. (Patrons now manage their profile inside the unified
/// Patron Edit dialog, so this standalone sheet is Authority-only.)
struct EditNostrProfileSheet: View {
    @Environment(\.dismiss) private var dismiss

    let npub: String
    var initialDisplayName: String = ""

    @State private var name = ""
    @State private var about = ""
    @State private var picture = ""
    @State private var nip05 = ""
    @State private var website = ""
    @State private var lud16 = ""
    @State private var loading = true
    @State private var publishing = false
    @State private var status: String?
    @State private var statusIsError = false
    @State private var showAvatarPicker = false

    private let service = NostrProfileService()

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    Text(npub)
                        .font(.callout).monospaced().textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .help("Your Nostr public key. The profile is signed by this key and published to your relays.")
                }

                Section("Name") {
                    TextField("Display name", text: $name)
                }

                Section("Avatar") {
                    DisclosureGroup(isExpanded: $showAvatarPicker) {
                        AvatarPickerView(selectedURL: $picture)
                    } label: {
                        HStack {
                            Text("Avatar")
                            Spacer()
                            AvatarView(value: picture, size: 30)
                        }
                    }
                }

                Section("About") {
                    TextField("About", text: $about, axis: .vertical).lineLimit(3 ... 6)
                }

                Section("NIP-05") {
                    TextField("user@domain.org", text: $nip05)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.callout)
                        .help("Optional. A Nostr-verifiable name, e.g. curator@example.org.")
                }

                Section("Website") {
                    TextField("https://example.com", text: $website)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.callout)
                }

                Section("Lightning Address") {
                    TextField("you@wallet.com", text: $lud16)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .font(.callout)
                        .help("Optional. A Lightning (LNURL-pay) address for receiving sats.")
                }

                Section {
                    Button {
                        Task { await publish() }
                    } label: {
                        HStack {
                            if publishing { ProgressView().controlSize(.small) }
                            Text(publishing ? "Publishing…" : "Publish to Nostr")
                        }
                    }
                    .disabled(publishing || loading)
                } footer: {
                    if let status {
                        Text(status).foregroundStyle(statusIsError ? .red : .green)
                    }
                }
            }
            .navigationTitle("Nostr Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
            .overlay {
                if loading { ProgressView("Reading from relays…") }
            }
        }
    }

    private func load() async {
        loading = true
        if let m = await service.fetch(npub: npub) {
            name = m.display_name ?? m.name ?? initialDisplayName
            about = m.about ?? ""
            picture = m.picture ?? ""
            nip05 = m.nip05 ?? ""
            website = m.website ?? ""
            lud16 = m.lud16 ?? ""
        } else {
            name = initialDisplayName
        }
        loading = false
    }

    private func publish() async {
        publishing = true
        status = nil
        let meta = NostrProfileMetadata(
            name: name, display_name: name, about: about, picture: picture,
            nip05: nip05, website: website, lud16: lud16
        )
        do {
            let results = try await service.publish(npub: npub, metadata: meta)
            let ok = results.filter { $0.1 }.count
            statusIsError = ok == 0
            status = ok > 0
                ? "Published to \(ok)/\(results.count) relays."
                : "No relay accepted the event."
        } catch {
            statusIsError = true
            status = error.localizedDescription
        }
        publishing = false
    }
}
