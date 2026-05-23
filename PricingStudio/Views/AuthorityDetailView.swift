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
    @State private var onboardingStatus: MCPService.OnboardingStatus?
    @State private var loadingOnboarding = false
    @State private var showingForgetConfirm = false
    @State private var forgetState: ForgetState = .idle

    private enum ForgetState {
        case idle, forgetting, done(String), error(String)
    }

    private var isLinked: Bool {
        KeychainService.loadNsec(forNpub: authority.npub) != nil
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
                }
                Divider()
                connectedOperatorsSection
            }
        }
        // navigationTitle removed — shared entityHeader provides the name
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
        .sheet(isPresented: $showingTopOff) {
            if let endpoint = authority.mcpEndpointURL {
                AuthorityTopOffSheet(
                    authorityName: authority.displayName,
                    authorityNpub: authority.npub,
                    endpoint: endpoint,
                    balanceVM: balanceVM,
                    authority: authority,
                    beneficiaryDisplayName: authority.displayName
                )
            }
        }
        .sheet(item: $fundingOperator) { op in
            if let endpoint = authority.mcpEndpointURL {
                AuthorityTopOffSheet(
                    authorityName: "\(op.displayName) at \(authority.displayName)",
                    authorityNpub: authority.npub,
                    endpoint: endpoint,
                    balanceVM: balanceVM,
                    authority: authority,
                    purchaserNpub: op.npub,
                    beneficiaryDisplayName: op.displayName
                )
            }
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
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: - Authority Balance

    @ViewBuilder
    private var authorityBalanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Authority Balance", systemImage: "creditcard.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showingTopOff = true
                } label: {
                    Label("Top Off", systemImage: "bolt.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(.green)
                Button {
                    Task { await balanceVM.loadBalance(for: authority) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            switch balanceVM.balanceState {
            case .idle:
                Text("Tap refresh to check balance")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .onAppear {
                        Task { await balanceVM.loadBalance(for: authority) }
                    }
            case .loading:
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("Loading...").font(.caption).foregroundStyle(.secondary)
                }
            case .loaded(let result):
                let isUnknown = result.balanceApiSats == 0 && result.totalDeposited == 0
                let balanceColor: Color = isUnknown ? .secondary : (result.balanceApiSats < 50 ? .red : .primary)
                HStack(spacing: 16) {
                    Text(isUnknown ? "N/A" : "\(result.balanceApiSats) sats")
                        .font(.subheadline.monospacedDigit().bold())
                        .foregroundStyle(balanceColor)

                    if result.pendingInvoiceCount > 0 {
                        Text("\(result.pendingInvoiceCount) pending")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }

                    Spacer()

                    if !result.pendingInvoiceIds.isEmpty {
                        Button {
                            Task { await balanceVM.reconcile(authority: authority, pendingIds: result.pendingInvoiceIds) }
                        } label: {
                            if balanceVM.isReconciling {
                                ProgressView().controlSize(.mini)
                            } else {
                                Label("Reconcile", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.caption2)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(balanceVM.isReconciling)
                    }
                }

                if !isUnknown && result.balanceApiSats < 50 {
                    Label("Low balance — operators may fail to certify purchases", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }

                if let rr = balanceVM.reconcileResult {
                    HStack(spacing: 6) {
                        if rr.settled > 0 {
                            Label("+\(rr.creditsGained)", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        if rr.expired > 0 {
                            Label("\(rr.expired) expired", systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                    .font(.caption2)
                }

            case .error(let msg):
                let isAuthIssue = msg.localizedCaseInsensitiveContains("auth")
                    || msg.localizedCaseInsensitiveContains("token")
                    || msg.localizedCaseInsensitiveContains("401")
                    || msg.localizedCaseInsensitiveContains("403")
                    || msg.localizedCaseInsensitiveContains("OAuth")
                HStack(spacing: 8) {
                    Text("??? sats")
                        .font(.subheadline.monospacedDigit().bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isAuthIssue {
                        Label("Authenticating…", systemImage: "key.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Button {
                        Task { await balanceVM.loadBalance(for: authority) }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                Text(isAuthIssue ? "Authentication in progress — tap Retry after signing in." : msg)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
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
                            missingSecrets: status.missing
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

    // MARK: - Connected Operators

    private var connectedOperatorsSection: some View {
        ConnectedOperatorsList(
            authorityNpub: authority.npub,
            authorityEndpointURL: authority.mcpEndpointURL,
            onOperatorSelected: onOperatorSelected,
            onFundOperator: { op in fundingOperator = op },
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
    var onAdopt: (() -> Void)?
    @Query private var allOperators: [Operator]
    @Environment(\.modelContext) private var modelContext
    @State private var deregisterError: String?
    @State private var operatorBalances: [String: Int] = [:]  // npub → balance

    init(authorityNpub: String, authorityEndpointURL: String? = nil, onOperatorSelected: ((Operator) -> Void)? = nil, onFundOperator: ((Operator) -> Void)? = nil, onAdopt: (() -> Void)? = nil) {
        self.authorityNpub = authorityNpub
        self.authorityEndpointURL = authorityEndpointURL
        self.onOperatorSelected = onOperatorSelected
        self.onFundOperator = onFundOperator
        self.onAdopt = onAdopt
        self._allOperators = Query(sort: \Operator.addedAt)
    }

    private var connectedOperators: [Operator] {
        allOperators.filter { $0.authorityNpub == authorityNpub }
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

            if connectedOperators.isEmpty {
                Text("No connected operators")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(connectedOperators) { op in
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
                                Button(role: .destructive) {
                                    Task { await deregisterOperator(op) }
                                } label: {
                                    Label("Disconnect from Authority", systemImage: "minus.circle")
                                }
                            }
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
    }

    private func loadOperatorBalances() async {
        guard let endpointString = authorityEndpointURL,
              let endpointURL = URL(string: endpointString) else { return }
        let mcpService = MCPService()
        for op in connectedOperators {
            do {
                let result = try await mcpService.callCheckBalance(
                    endpointURL: endpointURL,
                    patronNpub: op.npub
                )
                operatorBalances[op.npub] = result.balanceApiSats
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
                authorityNpub: authority.npub
            )
        } catch {
            // Log but don't block — still clear the local link
            deregisterError = "Registry removal failed: \(error.localizedDescription). Local link cleared."
        }

        // Always clear local authority link
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
                    .disabled(selectedOperator == nil || authorityVM.adoptionStatus == .registering)
                }
            }
        }
    }
}

// MARK: - Authority Top Off Sheet

struct AuthorityTopOffSheet: View {
    let authorityName: String
    let authorityNpub: String
    let endpoint: String
    let balanceVM: AuthorityBalanceViewModel
    let authority: Authority
    var purchaserNpub: String = ""  // if non-empty, used instead of authorityNpub for purchase identity
    /// Caller-supplied display name for whichever beneficiary npub will be
    /// shown (authorityNpub when purchaserNpub is blank, otherwise
    /// purchaserNpub). Bypasses the SwiftData walk when the parent already
    /// knows the obvious owner of that npub.
    var beneficiaryDisplayName: String? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var selectedAmount = 1000
    @State private var customAmount = ""
    @State private var purchaseState: PurchaseState = .idle
    @State private var paymentCheckState: PaymentCheckState = .idle
    @State private var proofState: ProofExchangeState = .idle

    private let presets = [500, 1000, 5000, 10000]
    private let mcpService = MCPService()

    private enum PurchaseState {
        case idle, purchasing
        case success(MCPService.PurchaseResult)
        case error(String)
    }

    /// Inline proof-exchange state. Two paths:
    /// (a) auto-sign — App holds the purchaser's nsec, sends the poison
    /// reply DM itself and proceeds to verifying. Initial click = consent.
    /// (b) human-in-the-loop — no nsec in Keychain, stops at `awaitingReply`
    /// and the user replies via their own Nostr client.
    private enum ProofExchangeState: Equatable {
        case idle, requesting, signingReply, awaitingReply, verifying
        case failed(String)
    }

    /// The npub doing the purchasing — this is whose ownership the cashier
    /// is asking us to prove. Mirrors the value the dialog uses for
    /// purchase / payment-check calls.
    private var purchaserIdentityNpub: String {
        purchaserNpub.isEmpty ? authorityNpub : purchaserNpub
    }

    /// Whether the App can complete the proof without further human action —
    /// requires the purchaser's nsec in Keychain. The cashier npub
    /// (`authorityNpub`) is always known in this sheet.
    private var canAutoSign: Bool {
        KeychainService.loadNsec(forNpub: purchaserIdentityNpub) != nil
    }

    private enum PaymentCheckState {
        case idle, checking, checked(String)
        var isChecking: Bool { if case .checking = self { return true }; return false }
    }

    private var effectiveAmount: Int {
        if let val = Int(customAmount), val > 0 { return val }
        return selectedAmount
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Beneficiary") {
                        beneficiaryLabel(purchaserNpub.isEmpty ? authorityNpub : purchaserNpub)
                    }
                    LabeledContent("Cashier") {
                        Text(authorityName)
                            .font(.subheadline.bold())
                    }
                } header: {
                    Text("Purchase Cert-Sats")
                } footer: {
                    Text("Cert-sats fund the beneficiary's certification capacity at \(authorityName). Anyone can pay the Lightning invoice.")
                        .font(.caption2)
                }

                Section("Amount (sats)") {
                    HStack(spacing: 8) {
                        ForEach(presets, id: \.self) { amount in
                            Button("\(amount)") {
                                selectedAmount = amount
                                customAmount = ""
                            }
                            .buttonStyle(.bordered)
                            .tint(selectedAmount == amount && customAmount.isEmpty ? .accentColor : .secondary)
                            .controlSize(.small)
                        }
                    }
                    TextField("Custom amount", text: $customAmount)
                        .keyboardType(.numberPad)
                        .onChange(of: customAmount) { _, newValue in
                            if let val = Int(newValue), val > 0 { selectedAmount = val }
                        }
                }

                switch purchaseState {
                case .idle:
                    Section {
                        Button {
                            purchase()
                        } label: {
                            Label("Purchase \(effectiveAmount) sats", systemImage: "bolt.fill")
                        }
                        .disabled(effectiveAmount < 100)
                    }

                case .purchasing:
                    Section {
                        HStack { ProgressView(); Text("Creating invoice...").foregroundStyle(.secondary) }
                    }

                case .success(let result):
                    Section("Invoice") {
                        if let bolt11 = result.lightningInvoice {
                            QRCodeView("lightning:\(bolt11)", size: 220)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                            Text(bolt11)
                                .font(.system(size: 9, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .foregroundStyle(.secondary)
                        }

                        if !result.checkoutLink.isEmpty, let url = URL(string: result.checkoutLink) {
                            Link(destination: url) {
                                Label("Open Payment Page", systemImage: "arrow.up.right.square")
                                    .font(.caption)
                            }
                        }

                        if !result.invoiceId.isEmpty {
                            Button {
                                checkPayment(invoiceId: result.invoiceId)
                            } label: {
                                if case .checking = paymentCheckState {
                                    HStack { ProgressView().controlSize(.small); Text("Checking...") }
                                } else {
                                    Label("Check Payment", systemImage: "arrow.triangle.2.circlepath")
                                }
                            }
                            .disabled(paymentCheckState.isChecking)
                        }

                        if case .checked(let msg) = paymentCheckState {
                            Text(msg).font(.caption).foregroundStyle(.green)
                        }
                    }

                    Section {
                        Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
                    }

                case .error(let message):
                    if TopOffSheet.isProofRequired(message) {
                        proofExchangeSection(rawError: message)
                    } else {
                        Section {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red).font(.caption)
                            Button("Retry") { purchase() }
                        }
                    }
                }
            }
            .navigationTitle("Purchase Cert-Sats")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        // Drag-down detents so the user can reach the Messages tab to
        // reply to the proof-challenge DM without losing the in-flight
        // proof exchange or staged amount selection.
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationContentInteraction(.scrolls)
    }

    private func purchase() {
        purchaseState = .purchasing
        Task {
            do {
                guard let endpointURL = URL(string: endpoint) else {
                    throw MCPError.connectionFailed("Invalid endpoint")
                }
                let result = try await mcpService.callPurchaseCredits(
                    endpointURL: endpointURL,
                    amountSats: effectiveAmount,
                    patronNpub: purchaserIdentityNpub
                )
                purchaseState = .success(result)
            } catch {
                purchaseState = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Proof Exchange (human-in-the-loop)

    @ViewBuilder
    private func proofExchangeSection(rawError: String) -> some View {
        Section {
            Label("Identity Proof Required", systemImage: "key.fill")
                .foregroundStyle(.orange)
                .font(.subheadline.bold())

            if canAutoSign {
                Text("\(authorityName) needs a fresh Nostr proof that the purchaser owns this npub. The purchaser's nsec is in this device's Keychain, so the App can complete the exchange.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(authorityName) needs a fresh Nostr proof that the purchaser owns this npub. Send the challenge, reply in your Nostr client, then verify. Drag this sheet down to use the Messages tab without losing progress.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            switch proofState {
            case .idle:
                if canAutoSign {
                    Button {
                        autoCompleteProof()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "key.fill")
                            Text("Prove identity with stored nsec")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        sendProofChallenge()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "paperplane.fill")
                            Text("Send DM challenge")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

            case .requesting:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Sending challenge DM…").foregroundStyle(.secondary).font(.caption)
                }

            case .signingReply:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Signing reply with the purchaser's nsec and publishing to relays…")
                        .foregroundStyle(.secondary).font(.caption)
                }

            case .awaitingReply:
                Label("Challenge sent. Open your Nostr client (or drag this sheet down and use the Messages tab) to reply to \(authorityName), then tap Verify.", systemImage: "envelope.badge")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    verifyProofAndRetry()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield.fill")
                        Text("I've replied — verify & retry")
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("Cancel proof exchange", role: .cancel) {
                    proofState = .idle
                }
                .font(.caption)

            case .verifying:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Verifying proof and retrying purchase…").foregroundStyle(.secondary).font(.caption)
                }

            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Try again") {
                    if canAutoSign { autoCompleteProof() } else { sendProofChallenge() }
                }
            }
        } footer: {
            Text(rawError)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func sendProofChallenge() {
        guard let endpointURL = URL(string: endpoint) else {
            proofState = .failed("Invalid endpoint URL")
            return
        }
        proofState = .requesting
        Task {
            do {
                _ = try await mcpService.callRequestNpubProof(
                    endpointURL: endpointURL,
                    patronNpub: purchaserIdentityNpub
                )
                proofState = .awaitingReply
            } catch {
                proofState = .failed(error.localizedDescription)
            }
        }
    }

    private func verifyProofAndRetry() {
        guard let endpointURL = URL(string: endpoint) else {
            proofState = .failed("Invalid endpoint URL")
            return
        }
        proofState = .verifying
        Task {
            do {
                _ = try await mcpService.callReceiveNpubProof(
                    endpointURL: endpointURL,
                    patronNpub: purchaserIdentityNpub
                )
                proofState = .idle
                purchase()
            } catch {
                proofState = .failed(error.localizedDescription)
            }
        }
    }

    /// Single-click proof completion — App holds the purchaser's nsec.
    /// With wheel v0.23 the proof gate accepts an inline Schnorr proof on
    /// the first call, so argsWithProof inside MCPService signs the
    /// kind-27235 event automatically. No relay round-trip needed; just
    /// retry the purchase.
    private func autoCompleteProof() {
        guard KeychainService.loadNsec(forNpub: purchaserIdentityNpub) != nil else {
            proofState = .failed("Purchaser nsec is no longer in Keychain — falling back to manual exchange.")
            return
        }
        proofState = .idle
        purchase()
    }

    private func checkPayment(invoiceId: String) {
        paymentCheckState = .checking
        Task {
            do {
                guard let endpointURL = URL(string: endpoint) else { return }
                let result = try await mcpService.callCheckPayment(
                    endpointURL: endpointURL,
                    invoiceId: invoiceId,
                    npub: authorityNpub
                )
                if result.status == "Settled" || result.creditsGranted > 0 {
                    paymentCheckState = .checked("Settled! +\(result.creditsGranted) sats credited.")
                    Task { await balanceVM.loadBalance(for: authority) }
                } else if result.status == "Expired" {
                    paymentCheckState = .checked("Invoice expired.")
                } else {
                    paymentCheckState = .checked(result.message.isEmpty ? "Not yet paid." : result.message)
                }
            } catch {
                paymentCheckState = .checked("Error: \(error.localizedDescription)")
            }
        }
    }

    /// Beneficiary label — prefers a caller-supplied display name (the
    /// "obvious choice" from the parent view's context), falls back to the
    /// SwiftData walk across Patron / Operator / Authority / Contact, and
    /// finally renders a truncated raw npub.
    @ViewBuilder
    private func beneficiaryLabel(_ npub: String) -> some View {
        let hint = beneficiaryDisplayName?.trimmingCharacters(in: .whitespaces)
        if let h = hint, !h.isEmpty {
            Text(h)
                .font(.subheadline.bold())
                .foregroundStyle(.green)
        } else if let name = NpubNameResolver.displayName(for: npub, in: modelContext) {
            Text(name)
                .font(.subheadline.bold())
                .foregroundStyle(.green)
        } else {
            Text(String(npub.prefix(16)) + "…")
                .font(.caption.monospaced())
                .foregroundStyle(.green)
        }
    }

}
