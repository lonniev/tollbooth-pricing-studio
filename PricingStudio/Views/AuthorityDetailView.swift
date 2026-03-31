import SwiftUI
import SwiftData

struct AuthorityDetailView: View {
    let authority: Authority
    @Bindable var pricingVM: PricingViewModel
    var authorityVM: AuthorityCollectionViewModel?
    var onOperatorSelected: ((Operator) -> Void)?
    @State private var balanceVM = AuthorityBalanceViewModel()
    @State private var showingTopOff = false

    private var isLinked: Bool {
        KeychainService.loadNsec(forNpub: authority.npub) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            authorityHeader
            Divider()
            if !isLinked { claimAuthorityButton }
            if authority.mcpEndpointURL != nil {
                Divider()
                authorityBalanceSection
            }
            Divider()
            connectedOperatorsSection
            Divider()
            pricingSection
        }
        .navigationTitle(authority.displayName)
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
                    authority: authority
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
                Label("Link Identity", systemImage: "person.badge.key.fill")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
            .controlSize(.small)
        }
    }

    // MARK: - Header

    private var authorityHeader: some View {
        VStack(spacing: 12) {
            Image(systemName: "building.columns.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            HStack(spacing: 4) {
                Text(authority.displayName)
                    .font(.title2.bold())
                if (DMPollingService.shared.unreadCounts[authority.npub] ?? 0) > 0 {
                    Image(systemName: "envelope.badge.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Text(authority.npub)
                .font(.caption)
                .monospaced()
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 8) {
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
        }
        .padding()
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

    // MARK: - Connected Operators

    private var connectedOperatorsSection: some View {
        ConnectedOperatorsList(
            authorityNpub: authority.npub,
            authorityEndpointURL: authority.mcpEndpointURL,
            onOperatorSelected: onOperatorSelected,
            onAdopt: authority.mcpEndpointURL != nil && authorityVM != nil
                ? { authorityVM?.requestAdopt(authority) }
                : nil
        )
    }

    // MARK: - Pricing

    @ViewBuilder
    private var pricingSection: some View {
        if authority.mcpEndpointURL != nil {
            PricingDetailView(target: authority, viewModel: pricingVM)
                .frame(maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "No MCP Endpoint",
                systemImage: "link.badge.plus",
                description: Text("This authority's MCP endpoint hasn't been discovered yet.")
            )
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Connected Operators List

/// Shows operators whose authorityNpub matches this authority.
private struct ConnectedOperatorsList: View {
    let authorityNpub: String
    let authorityEndpointURL: String?
    var onOperatorSelected: ((Operator) -> Void)?
    var onAdopt: (() -> Void)?
    @Query private var allOperators: [Operator]
    @Environment(\.modelContext) private var modelContext
    @State private var deregisterError: String?

    init(authorityNpub: String, authorityEndpointURL: String? = nil, onOperatorSelected: ((Operator) -> Void)? = nil, onAdopt: (() -> Void)? = nil) {
        self.authorityNpub = authorityNpub
        self.authorityEndpointURL = authorityEndpointURL
        self.onOperatorSelected = onOperatorSelected
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
                                }
                                .frame(width: 80)
                                .padding(.vertical, 6)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
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

    private func deregisterOperator(_ op: Operator) async {
        guard let endpointString = authorityEndpointURL,
              let endpointURL = URL(string: endpointString) else {
            // No Authority endpoint — just clear local link
            op.authorityNpub = nil
            try? modelContext.save()
            return
        }

        let mcpService = MCPService()
        let oauthService = OAuthService()

        do {
            let host = endpointURL.host ?? authorityNpub
            let token: String
            if let bundle = KeychainService.loadTokenBundle(forPatron: op.npub, operator: host),
               !bundle.isExpired {
                token = bundle.accessToken
            } else {
                let bundle = try await oauthService.authenticate(mcpEndpoint: endpointURL)
                try? KeychainService.saveTokenBundle(bundle, forPatron: op.npub, operator: host)
                token = bundle.accessToken
            }

            _ = try await mcpService.callDeregisterOperator(
                endpointURL: endpointURL,
                bearerToken: token,
                operatorNpub: op.npub
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
                            let (_, token) = try await pricingVM.resolveEndpointAndToken(for: authority)
                            await authorityVM.adoptOperator(
                                authority: authority,
                                operatorToAdopt: op,
                                bearerToken: token,
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
    @Environment(\.dismiss) private var dismiss

    @State private var selectedAmount = 1000
    @State private var customAmount = ""
    @State private var purchaseState: PurchaseState = .idle
    @State private var paymentCheckState: PaymentCheckState = .idle

    private let presets = [500, 1000, 5000, 10000]
    private let mcpService = MCPService()

    private enum PurchaseState {
        case idle, purchasing
        case success(MCPService.PurchaseResult)
        case error(String)
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
                Section("Authority") {
                    Text(authorityName).font(.headline)
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
                        if !result.checkoutLink.isEmpty, let url = URL(string: result.checkoutLink) {
                            Link(destination: url) {
                                Label("Open Payment Page", systemImage: "arrow.up.right.square")
                            }
                        }

                        if let bolt11 = result.lightningInvoice {
                            Text(bolt11)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }

                        if !result.invoiceId.isEmpty {
                            LabeledContent("Invoice ID") {
                                Text(result.invoiceId)
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                            }
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
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).font(.caption)
                        Button("Retry") { purchase() }
                    }
                }
            }
            .navigationTitle("Top Off Authority")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func purchase() {
        purchaseState = .purchasing
        Task {
            do {
                guard let endpointURL = URL(string: endpoint) else {
                    throw MCPError.connectionFailed("Invalid endpoint")
                }
                let host = endpointURL.host ?? authorityNpub
                let token = try await resolveToken(host: host, endpointURL: endpointURL)
                let result = try await mcpService.callPurchaseCredits(
                    endpointURL: endpointURL,
                    bearerToken: token,
                    amountSats: effectiveAmount,
                    patronNpub: purchaserNpub.isEmpty ? authorityNpub : purchaserNpub
                )
                purchaseState = .success(result)
            } catch {
                purchaseState = .error(error.localizedDescription)
            }
        }
    }

    private func checkPayment(invoiceId: String) {
        paymentCheckState = .checking
        Task {
            do {
                guard let endpointURL = URL(string: endpoint) else { return }
                let host = endpointURL.host ?? authorityNpub
                let token = try await resolveToken(host: host, endpointURL: endpointURL)
                let result = try await mcpService.callCheckPayment(
                    endpointURL: endpointURL,
                    bearerToken: token,
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

    private func resolveToken(host: String, endpointURL: URL) async throws -> String {
        if let bundle = KeychainService.loadTokenBundle(forPatron: authorityNpub, operator: host) {
            if !bundle.isExpired { return bundle.accessToken }
        }
        let bundle = try await OAuthService().authenticate(mcpEndpoint: endpointURL)
        try KeychainService.saveTokenBundle(bundle, forPatron: authorityNpub, operator: host)
        return bundle.accessToken
    }
}
