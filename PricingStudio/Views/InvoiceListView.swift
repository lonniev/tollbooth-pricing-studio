import SwiftUI
import SwiftData

struct InvoiceListView: View {
    let patronNpub: String
    @Bindable var accountVM: PatronAccountViewModel
    var onOpenMessages: ((_ operatorNpub: String) -> Void)?
    @Query(sort: \Operator.addedAt) private var operators: [Operator]

    init(patron: Patron, accountVM: PatronAccountViewModel, onOpenMessages: ((_ operatorNpub: String) -> Void)? = nil) {
        self.patronNpub = patron.npub
        self.accountVM = accountVM
        self.onOpenMessages = onOpenMessages
    }

    init(patronNpub: String, accountVM: PatronAccountViewModel, onOpenMessages: ((_ operatorNpub: String) -> Void)? = nil) {
        self.patronNpub = patronNpub
        self.accountVM = accountVM
        self.onOpenMessages = onOpenMessages
    }

    @State private var isReconciling = false
    @State private var reconcileResults: [String: PatronAccountViewModel.ReconcileResult] = [:]
    @State private var checkingInvoices: Set<String> = []
    @State private var invoiceStatuses: [String: String] = [:]
    @State private var hasLoadedHistory = false
    @State private var topOffOperator: TopOffTarget?

    private struct TopOffTarget: Identifiable {
        let id: String  // operator npub
        let operatorName: String
        let endpoint: String
    }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                summaryHeader
                reconcileAllButton
                invoiceHistoryByOperator
            }
            .padding()
        }
        .navigationTitle("Invoices")
        .task {
            guard !hasLoadedHistory else { return }
            hasLoadedHistory = true
            await accountVM.loadAllInvoiceHistory(forNpub: patronNpub, operators: operators)
        }
        .sheet(item: $topOffOperator) { target in
            TopOffSheet(
                patronNpub: patronNpub,
                operatorName: target.operatorName,
                endpoint: target.endpoint,
                accountVM: accountVM,
                onNotifyOperator: onOpenMessages.map { callback in
                    { callback(target.id) }
                }
            )
        }
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

    // MARK: - Invoice History by Operator

    @ViewBuilder
    private var invoiceHistoryByOperator: some View {
        let mcpOperators = operators.filter { $0.mcpEndpointURL != nil }

        if mcpOperators.isEmpty {
            ContentUnavailableView(
                "No Operators",
                systemImage: "server.rack",
                description: Text("Add an operator to view invoice history.")
            )
            .padding(.top, 32)
        } else {
            ForEach(mcpOperators) { op in
                operatorInvoiceHistorySection(op: op)
            }
        }
    }

    @ViewBuilder
    private func operatorInvoiceHistorySection(op: Operator) -> some View {
        let historyState = accountVM.invoiceHistoryStates[op.npub] ?? .idle

        VStack(alignment: .leading, spacing: 8) {
            // Operator header
            HStack {
                Image(systemName: "server.rack")
                    .foregroundStyle(.orange)
                Text(op.displayName)
                    .font(.headline)
                Spacer()

                if let rr = reconcileResults[op.npub] {
                    reconcileResultBadge(rr)
                }

                Button {
                    topOffOperator = TopOffTarget(
                        id: op.npub,
                        operatorName: op.displayName,
                        endpoint: op.mcpEndpointURL ?? ""
                    )
                } label: {
                    Label("Top Off", systemImage: "plus.circle.fill")
                        .font(.caption.bold())
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }

            Divider()

            switch historyState {
            case .idle:
                Text("Not loaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .loading:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading invoice history...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            case .loaded(let items):
                if items.isEmpty {
                    Text("No invoices yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    invoiceTable(items: items, endpoint: op.mcpEndpointURL ?? "")
                }
            case .error(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.vertical, 4)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func invoiceTable(items: [MCPService.InvoiceLineItem], endpoint: String) -> some View {
        // Column headers
        HStack(spacing: 0) {
            Text("Date")
                .frame(width: 130, alignment: .leading)
            Text("Amount")
                .frame(width: 70, alignment: .trailing)
            Text("Credits")
                .frame(width: 70, alignment: .trailing)
            Text("Status")
                .frame(minWidth: 60, alignment: .center)
            Spacer()
        }
        .font(.caption2.bold())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)

        ForEach(items) { item in
            invoiceLineItemRow(item: item, endpoint: endpoint)
        }
    }

    @ViewBuilder
    private func invoiceLineItemRow(item: MCPService.InvoiceLineItem, endpoint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                // Date
                Group {
                    if let date = item.createdAt {
                        Text(Self.dateFormatter.string(from: date))
                    } else {
                        Text("--")
                    }
                }
                .frame(width: 130, alignment: .leading)

                // Amount (real sats)
                Text("\(item.amountSats)")
                    .frame(width: 70, alignment: .trailing)

                // Credits granted
                Text(item.apiSatsCredited > 0 ? "\(item.apiSatsCredited)" : "--")
                    .frame(width: 70, alignment: .trailing)

                // Status badge
                statusBadge(for: item.status)
                    .frame(minWidth: 60, alignment: .center)

                Spacer()

                // Check button for pending invoices
                if item.status == "Pending" {
                    Button {
                        Task { await checkSingleInvoice(invoiceId: item.id, endpoint: endpoint) }
                    } label: {
                        if checkingInvoices.contains(item.id) {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(checkingInvoices.contains(item.id))
                }
            }
            .font(.caption.monospacedDigit())

            // Invoice tracking ID
            Text(item.id)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)

        // Show override status from reconcile check
        if let overrideStatus = invoiceStatuses[item.id] {
            Text(overrideStatus)
                .font(.caption2)
                .foregroundStyle(statusColor(for: overrideStatus))
                .padding(.leading, 8)
        }
    }

    @ViewBuilder
    private func statusBadge(for status: String) -> some View {
        Text(status)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor(for: status).opacity(0.15), in: Capsule())
            .foregroundStyle(statusColor(for: status))
    }

    @ViewBuilder
    private func reconcileResultBadge(_ rr: PatronAccountViewModel.ReconcileResult) -> some View {
        HStack(spacing: 4) {
            if rr.settled > 0 {
                Label("\(rr.settled)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if rr.expired > 0 {
                Label("\(rr.expired)", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
            if rr.stillPending > 0 {
                Label("\(rr.stillPending)", systemImage: "clock")
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
                    patronNpub: patronNpub,
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

        // Refresh balances and invoice history
        await accountVM.forceRefresh(forNpub: patronNpub, operators: operators)
        await accountVM.loadAllInvoiceHistory(forNpub: patronNpub, operators: operators)
        isReconciling = false
    }

    private func checkSingleInvoice(invoiceId: String, endpoint: String) async {
        checkingInvoices.insert(invoiceId)
        do {
            let rr = try await accountVM.reconcilePendingInvoices(
                patronNpub: patronNpub,
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

        // Derive from invoice history when available
        for (_, historyState) in accountVM.invoiceHistoryStates {
            if case .loaded(let items) = historyState {
                for item in items {
                    switch item.status {
                    case "Pending":
                        stats.totalPending += 1
                    case "Settled":
                        stats.totalSettled += 1
                        stats.totalCredits += item.apiSatsCredited
                    default:
                        break
                    }
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
        if status == "Expired" || status == "Invalid" { return .red }
        if status == "Pending" || status == "Still pending" { return .orange }
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
