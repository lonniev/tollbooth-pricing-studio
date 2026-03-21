import SwiftUI
import SwiftData

struct InvoiceListView: View {
    let patron: Patron
    @Bindable var accountVM: PatronAccountViewModel
    @Query(sort: \Operator.addedAt) private var operators: [Operator]

    @State private var isReconciling = false
    @State private var reconcileResults: [String: PatronAccountViewModel.ReconcileResult] = [:]
    @State private var checkingInvoices: Set<String> = []
    @State private var invoiceStatuses: [String: String] = [:]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                summaryHeader
                reconcileAllButton
                invoicesByOperator
            }
            .padding()
        }
        .navigationTitle("Invoices")
    }

    // MARK: - Summary Header

    @ViewBuilder
    private var summaryHeader: some View {
        let stats = aggregateStats

        VStack(spacing: 8) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)

            Text("Invoice Summary")
                .font(.title3.bold())

            HStack(spacing: 24) {
                StatBadge(
                    label: "Pending",
                    value: "\(stats.totalPending)",
                    color: stats.totalPending > 0 ? .orange : .secondary
                )
                StatBadge(
                    label: "Settled",
                    value: "\(stats.totalSettled)",
                    color: .green
                )
                StatBadge(
                    label: "Credits",
                    value: "\(stats.totalCredits) sats",
                    color: .blue
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Reconcile All

    @ViewBuilder
    private var reconcileAllButton: some View {
        let allPending = allPendingInvoices
        if !allPending.isEmpty {
            Button {
                Task { await reconcileAll() }
            } label: {
                if isReconciling {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reconciling...")
                    }
                } else {
                    Label("Reconcile All (\(allPending.count))", systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline.bold())
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(isReconciling)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Invoices by Operator

    @ViewBuilder
    private var invoicesByOperator: some View {
        let balancesWithInvoices = accountVM.operatorBalances.filter { balance in
            if case .loaded(let result) = balance.balanceState {
                return !result.pendingInvoiceIds.isEmpty
            }
            return false
        }

        if balancesWithInvoices.isEmpty {
            ContentUnavailableView(
                "No Pending Invoices",
                systemImage: "checkmark.circle",
                description: Text("All invoices have been settled or there are no outstanding payments.")
            )
            .padding(.top, 32)
        } else {
            ForEach(balancesWithInvoices) { balance in
                if case .loaded(let result) = balance.balanceState {
                    operatorInvoiceSection(balance: balance, result: result)
                }
            }
        }
    }

    @ViewBuilder
    private func operatorInvoiceSection(
        balance: PatronAccountViewModel.OperatorBalance,
        result: PatronAccountViewModel.BalanceResult
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "server.rack")
                    .foregroundStyle(.orange)
                Text(balance.operatorName)
                    .font(.headline)
                Spacer()
                Text("\(result.pendingInvoiceIds.count) pending")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.2), in: Capsule())
                    .foregroundStyle(.orange)
            }

            if let rr = reconcileResults[balance.id] {
                reconcileResultBanner(rr)
            }

            Divider()

            ForEach(result.pendingInvoiceIds, id: \.self) { invoiceId in
                invoiceRow(invoiceId: invoiceId, endpoint: balance.endpoint)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func invoiceRow(invoiceId: String, endpoint: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(invoiceId)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let status = invoiceStatuses[invoiceId] {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(statusColor(for: status))
                }
            }

            Spacer()

            Button {
                Task { await checkSingleInvoice(invoiceId: invoiceId, endpoint: endpoint) }
            } label: {
                if checkingInvoices.contains(invoiceId) {
                    ProgressView().controlSize(.mini)
                } else {
                    Label("Check", systemImage: "magnifyingglass")
                        .font(.caption.bold())
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(checkingInvoices.contains(invoiceId))
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func reconcileResultBanner(_ rr: PatronAccountViewModel.ReconcileResult) -> some View {
        HStack(spacing: 8) {
            if rr.settled > 0 {
                Label("\(rr.settled) settled (+\(rr.creditsGained) sats)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if rr.expired > 0 {
                Label("\(rr.expired) expired", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
            if rr.stillPending > 0 {
                Label("\(rr.stillPending) still pending", systemImage: "clock")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption2)
    }

    // MARK: - Actions

    private func reconcileAll() async {
        isReconciling = true
        reconcileResults = [:]

        for balance in accountVM.operatorBalances {
            guard case .loaded(let result) = balance.balanceState,
                  !result.pendingInvoiceIds.isEmpty else { continue }

            do {
                let rr = try await accountVM.reconcilePendingInvoices(
                    patronNpub: patron.npub,
                    operatorEndpoint: balance.endpoint,
                    pendingInvoiceIds: result.pendingInvoiceIds
                )
                reconcileResults[balance.id] = rr
            } catch {
                reconcileResults[balance.id] = PatronAccountViewModel.ReconcileResult(
                    settled: 0, expired: 0,
                    stillPending: result.pendingInvoiceIds.count,
                    creditsGained: 0
                )
            }
        }

        // Refresh balances to pick up changes
        await accountVM.forceRefresh(for: patron, operators: operators)
        isReconciling = false
    }

    private func checkSingleInvoice(invoiceId: String, endpoint: String) async {
        checkingInvoices.insert(invoiceId)
        do {
            let rr = try await accountVM.reconcilePendingInvoices(
                patronNpub: patron.npub,
                operatorEndpoint: endpoint,
                pendingInvoiceIds: [invoiceId]
            )
            if rr.settled > 0 {
                invoiceStatuses[invoiceId] = "Settled (+\(rr.creditsGained) sats)"
            } else if rr.expired > 0 {
                invoiceStatuses[invoiceId] = "Expired"
            } else {
                invoiceStatuses[invoiceId] = "Still pending"
            }
        } catch {
            invoiceStatuses[invoiceId] = "Check failed"
        }
        checkingInvoices.remove(invoiceId)
    }

    // MARK: - Computed

    private struct AggregateStats {
        var totalPending = 0
        var totalSettled = 0
        var totalCredits = 0
    }

    private var aggregateStats: AggregateStats {
        var stats = AggregateStats()
        for balance in accountVM.operatorBalances {
            if case .loaded(let result) = balance.balanceState {
                stats.totalPending += result.pendingInvoiceCount
                if let summary = result.invoiceSummary {
                    stats.totalSettled += summary.settledCount
                    stats.totalCredits += summary.totalApiSatsCredited
                }
            }
        }
        // Include reconcile results from this session
        for (_, rr) in reconcileResults {
            stats.totalSettled += rr.settled
            stats.totalCredits += rr.creditsGained
        }
        return stats
    }

    private var allPendingInvoices: [(id: String, endpoint: String)] {
        accountVM.operatorBalances.compactMap { balance -> [(id: String, endpoint: String)]? in
            guard case .loaded(let result) = balance.balanceState else { return nil }
            return result.pendingInvoiceIds.map { (id: $0, endpoint: balance.endpoint) }
        }.flatMap { $0 }
    }

    private func statusColor(for status: String) -> Color {
        if status.hasPrefix("Settled") { return .green }
        if status == "Expired" { return .red }
        if status == "Still pending" { return .orange }
        return .secondary
    }
}

// MARK: - Stat Badge

private struct StatBadge: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
