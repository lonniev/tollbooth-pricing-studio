import SwiftUI
import SwiftData

/// Shows an operator's relationship with its Authority: balance, registration
/// status, and a Top Off action that funds the **operator's** account (not
/// the Authority's own balance).
struct OperatorAuthorityView: View {
    let `operator`: Operator
    let authorityNpub: String

    @Query private var authorities: [Authority]
    @State private var balanceVM = AuthorityBalanceViewModel()
    @State private var showingTopOff = false

    private var authority: Authority? {
        authorities.first { $0.npub == authorityNpub }
    }

    /// The store where this operator's balance lives — its Authority. Same
    /// shape every actor uses: you hold one balance, at your parent.
    private var source: InvoiceSource {
        InvoiceSource(
            npub: authorityNpub,
            displayName: authority?.displayName ?? "Authority",
            mcpEndpointURL: authority?.mcpEndpointURL
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                authorityCard
                operatorBalanceCard
            }
            .padding()
        }
        .task(id: `operator`.npub) {
            await loadOperatorBalance()
        }
        .sheet(isPresented: $showingTopOff) {
            if let auth = authority {
                PurchaseCreditsSheet(
                    cashierName: auth.displayName,
                    cashierNpub: auth.npub,
                    endpoint: auth.mcpEndpointURL ?? "",
                    purchaserNpub: `operator`.npub,
                    beneficiaryDisplayName: `operator`.displayName,
                    beneficiaryBadge: .operator,
                    cashierBadge: .authority,
                    presets: [500, 1000, 5000, 10000],
                    onSettled: { Task { await loadOperatorBalance() } }
                )
            }
        }
    }

    // MARK: - Authority Card

    @ViewBuilder
    private var authorityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "building.columns.fill")
                    .foregroundStyle(.blue)
                Text("Authority")
                    .font(.subheadline.bold())
                Spacer()
            }
            if let auth = authority {
                Text(auth.displayName)
                    .font(.headline)
                Text(auth.npub)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
            } else {
                Text(String(authorityNpub.prefix(20)) + "...")
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Account at parent (the operator's one balance, at its Authority)

    private var operatorBalanceCard: some View {
        ParentAccountCard(
            parentDisplayName: source.displayName,
            balance: balanceVM.balanceState,
            feeExplanation: "spent as the certification fee each time a patron buys",
            isReconciling: balanceVM.isReconciling,
            reconcileResult: balanceVM.reconcileResult,
            onTopUp: { showingTopOff = true },
            onReconcile: {
                guard case .loaded(let result) = balanceVM.balanceState else { return }
                Task {
                    await balanceVM.reconcileCertification(
                        authorityNpub: `operator`.npub,
                        source: source,
                        pendingIds: result.pendingInvoiceIds
                    )
                }
            },
            onRefresh: { Task { await loadOperatorBalance() } }
        )
    }

    // MARK: - Balance Loading

    private func loadOperatorBalance() async {
        await balanceVM.loadCertificationBalance(
            authorityNpub: `operator`.npub, source: source
        )
    }
}
