import SwiftUI
import SwiftData

struct AuthorityDetailView: View {
    let authority: Authority
    @Bindable var pricingVM: PricingViewModel
    var authorityVM: AuthorityCollectionViewModel?
    var onOperatorSelected: ((Operator) -> Void)?
    @State private var balanceVM = AuthorityBalanceViewModel()

    var body: some View {
        VStack(spacing: 0) {
            authorityHeader
            Divider()
            claimAuthorityButton
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

            Text(authority.displayName)
                .font(.title2.bold())

            Text(authority.npub)
                .font(.caption)
                .monospaced()
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if authority.isAutoDiscovered {
                Label("Auto-discovered", systemImage: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                    Task { await balanceVM.loadBalance(for: authority) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
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
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(result.balanceApiSats) sats")
                            .font(.subheadline.monospacedDigit().bold())
                            .foregroundStyle(result.balanceApiSats < 50 ? .red : .primary)
                        Text("tax reserve")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

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

                if result.balanceApiSats < 50 {
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
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
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
    var onOperatorSelected: ((Operator) -> Void)?
    var onAdopt: (() -> Void)?
    @Query private var allOperators: [Operator]

    init(authorityNpub: String, onOperatorSelected: ((Operator) -> Void)? = nil, onAdopt: (() -> Void)? = nil) {
        self.authorityNpub = authorityNpub
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
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 8)
            }
        }
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
