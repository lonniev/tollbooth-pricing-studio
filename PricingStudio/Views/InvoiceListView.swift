import SwiftUI
import SwiftData
import UIKit

struct InvoiceListView: View {
    let entityNpub: String
    @Bindable var accountVM: PatronAccountViewModel
    var onOpenMessages: ((_ operatorNpub: String) -> Void)?
    /// Explicit service sources override the @Query operators.
    /// Each entry is an Operator-shaped object with npub + mcpEndpointURL.
    private let explicitSources: [Operator]?
    @Query(sort: \Operator.addedAt) private var queriedOperators: [Operator]

    private var operators: [Operator] {
        explicitSources ?? queriedOperators
    }

    /// Patron viewing invoices across all operators.
    init(patron: Patron, accountVM: PatronAccountViewModel, onOpenMessages: ((_ operatorNpub: String) -> Void)? = nil) {
        self.entityNpub = patron.npub
        self.accountVM = accountVM
        self.onOpenMessages = onOpenMessages
        self.explicitSources = nil
    }

    /// Patron viewing invoices across all operators (npub variant).
    init(patronNpub: String, accountVM: PatronAccountViewModel, onOpenMessages: ((_ operatorNpub: String) -> Void)? = nil) {
        self.entityNpub = patronNpub
        self.accountVM = accountVM
        self.onOpenMessages = onOpenMessages
        self.explicitSources = nil
    }

    /// Operator viewing invoices at a specific Authority.
    init(operatorNpub: String, authority: Authority, accountVM: PatronAccountViewModel, onOpenMessages: ((_ operatorNpub: String) -> Void)? = nil) {
        self.entityNpub = operatorNpub
        self.accountVM = accountVM
        self.onOpenMessages = onOpenMessages
        // Wrap the Authority as an Operator-shaped source
        let source = Operator(npub: authority.npub, displayName: authority.displayName)
        source.mcpEndpointURL = authority.mcpEndpointURL
        self.explicitSources = [source]
    }

    @State private var isReconciling = false
    @State private var reconcileResults: [String: PatronAccountViewModel.ReconcileResult] = [:]
    @State private var checkingInvoices: Set<String> = []
    @State private var invoiceStatuses: [String: String] = [:]
    @State private var hasLoadedHistory = false
    @State private var showingExportSheet = false
    @State private var sortColumn: SortColumn = .date
    @State private var sortAscending = false
    @State private var hideExpired = false

    private enum SortColumn: String {
        case date, amount, credits, status
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
                filterBar
                reconcileAllButton
                invoiceHistoryByOperator
            }
            .padding()
        }
        .navigationTitle("Invoices")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingExportSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(allInvoiceItems.isEmpty)
            }
        }
        .task(id: entityNpub) {
            hasLoadedHistory = false
            await accountVM.loadAllInvoiceHistory(forNpub: entityNpub, operators: operators)
            hasLoadedHistory = true
        }
        .refreshable {
            await accountVM.forceRefresh(forNpub: entityNpub, operators: operators)
        }
        .sheet(isPresented: $showingExportSheet) {
            InvoiceExportSheet(
                patronNpub: entityNpub,
                allItems: allInvoiceItemsByOperator,
                dateFormatter: Self.dateFormatter
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

    // MARK: - Filter Bar

    @ViewBuilder
    private var filterBar: some View {
        HStack {
            Toggle(isOn: $hideExpired) {
                Label("Hide Expired", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.caption)
            }
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(hideExpired ? .accentColor : .secondary)

            Spacer()
        }
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
                let visible = sortedAndFiltered(items)
                if items.isEmpty {
                    Text("No invoices yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else if visible.isEmpty {
                    Text("All invoices hidden by filter")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    invoiceTable(items: visible, endpoint: op.mcpEndpointURL ?? "")
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

    // MARK: - Sorting & Filtering

    private func sortedAndFiltered(_ items: [MCPService.InvoiceLineItem]) -> [MCPService.InvoiceLineItem] {
        var result = items
        if hideExpired {
            result = result.filter { $0.status != "Expired" && $0.status != "Invalid" }
        }
        result.sort { a, b in
            let cmp: Bool
            switch sortColumn {
            case .date:
                cmp = (a.createdAt ?? .distantPast) < (b.createdAt ?? .distantPast)
            case .amount:
                cmp = a.amountSats < b.amountSats
            case .credits:
                cmp = a.apiSatsCredited < b.apiSatsCredited
            case .status:
                cmp = a.status < b.status
            }
            return sortAscending ? cmp : !cmp
        }
        return result
    }

    // MARK: - Invoice Table

    @ViewBuilder
    private func invoiceTable(items: [MCPService.InvoiceLineItem], endpoint: String) -> some View {
        // Column headers — tappable for sorting
        HStack(spacing: 0) {
            sortableHeader("Date", column: .date)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortableHeader("Amount", column: .amount)
                .frame(maxWidth: .infinity, alignment: .trailing)
            sortableHeader("Credits", column: .credits)
                .frame(maxWidth: .infinity, alignment: .trailing)
            sortableHeader("Status", column: .status)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.caption2.bold())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)

        ForEach(items) { item in
            invoiceLineItemRow(item: item, endpoint: endpoint)
        }
    }

    @ViewBuilder
    private func sortableHeader(_ title: String, column: SortColumn) -> some View {
        Button {
            if sortColumn == column {
                sortAscending.toggle()
            } else {
                sortColumn = column
                sortAscending = column == .status // status ascending by default, others descending
            }
        } label: {
            HStack(spacing: 2) {
                Text(title)
                if sortColumn == column {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
        }
        .buttonStyle(.plain)
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
                .frame(maxWidth: .infinity, alignment: .leading)

                // Amount (real sats)
                Text("\(item.amountSats)")
                    .frame(maxWidth: .infinity, alignment: .trailing)

                // Credits granted
                Text(item.apiSatsCredited > 0 ? "\(item.apiSatsCredited)" : "--")
                    .frame(maxWidth: .infinity, alignment: .trailing)

                // Status badge + optional check button
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    statusBadge(for: item.status)
                    if item.status == "Pending" {
                        Button {
                            Task { await checkSingleInvoice(invoiceId: item.id, endpoint: endpoint) }
                        } label: {
                            if checkingInvoices.contains(item.id) {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "magnifyingglass")
                                    .font(.caption2)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(checkingInvoices.contains(item.id))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.caption.monospacedDigit())

            // Invoice tracking ID — copyable
            Text(item.id)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
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
                    patronNpub: entityNpub,
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
        await accountVM.forceRefresh(forNpub: entityNpub, operators: operators)
        isReconciling = false
    }

    private func checkSingleInvoice(invoiceId: String, endpoint: String) async {
        checkingInvoices.insert(invoiceId)
        do {
            let rr = try await accountVM.reconcilePendingInvoices(
                patronNpub: entityNpub,
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

    /// All loaded invoice items, flat list for export.
    private var allInvoiceItems: [MCPService.InvoiceLineItem] {
        accountVM.invoiceHistoryStates.values.compactMap { state in
            if case .loaded(let items) = state { return items }
            return nil
        }.flatMap { $0 }
    }

    /// All loaded invoice items grouped by operator name, for export.
    private var allInvoiceItemsByOperator: [(operatorName: String, items: [MCPService.InvoiceLineItem])] {
        let mcpOperators = operators.filter { $0.mcpEndpointURL != nil }
        return mcpOperators.compactMap { op in
            guard case .loaded(let items) = accountVM.invoiceHistoryStates[op.npub],
                  !items.isEmpty else { return nil }
            return (operatorName: op.displayName, items: items)
        }
    }

    private func statusColor(for status: String) -> Color {
        if status.hasPrefix("Settled") { return .green }
        if status == "Expired" || status == "Invalid" { return .red }
        if status == "Pending" || status == "Still pending" { return .orange }
        return .secondary
    }
}

// MARK: - Export Sheet

private struct InvoiceExportSheet: View {
    let patronNpub: String
    let allItems: [(operatorName: String, items: [MCPService.InvoiceLineItem])]
    let dateFormatter: DateFormatter
    @Environment(\.dismiss) private var dismiss
    @State private var showingShareSheet = false
    @State private var exportItems: [Any] = []

    private var totalCount: Int {
        allItems.reduce(0) { $0 + $1.items.count }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("\(totalCount) invoices across \(allItems.count) operator(s)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Export As") {
                    Button {
                        exportCSV()
                    } label: {
                        Label("CSV Spreadsheet", systemImage: "tablecells")
                    }

                    Button {
                        exportPDF()
                    } label: {
                        Label("PDF Document", systemImage: "doc.richtext")
                    }

                    Button {
                        exportImage()
                    } label: {
                        Label("Image (PNG)", systemImage: "photo")
                    }
                }
            }
            .navigationTitle("Export Invoices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                InvoiceShareSheet(items: exportItems)
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    // MARK: - CSV

    private static let csvDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df
    }()

    private func exportCSV() {
        var csv = "Operator,Invoice ID,Status,Amount (sats),Credits,Multiplier,Created,Settled\n"
        for group in allItems {
            for item in group.items {
                let created = item.createdAt.map { Self.csvDateFormatter.string(from: $0) } ?? ""
                let settled = item.settledAt.map { Self.csvDateFormatter.string(from: $0) } ?? ""
                let escapedId = item.id.contains(",") ? "\"\(item.id)\"" : item.id
                csv += "\(group.operatorName),\(escapedId),\(item.status),\(item.amountSats),\(item.apiSatsCredited),\(item.multiplier),\(created),\(settled)\n"
            }
        }
        let filename = "invoices-\(shortNpub).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        exportItems = [url]
        showingShareSheet = true
    }

    // MARK: - PDF

    private func exportPDF() {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { context in
            context.beginPage()
            var y: CGFloat = 40

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 16)
            ]
            let headerAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 9),
                .foregroundColor: UIColor.secondaryLabel
            ]
            let cellAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
            ]
            let sectionAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 12),
                .foregroundColor: UIColor.label
            ]
            let idAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 7, weight: .regular),
                .foregroundColor: UIColor.secondaryLabel
            ]

            let title = "Invoice Report — \(shortNpub)"
            (title as NSString).draw(at: CGPoint(x: 40, y: y), withAttributes: titleAttrs)
            y += 28

            let colX: [CGFloat] = [40, 160, 230, 300, 380]
            let headers = ["Date", "Amount", "Credits", "Status", "Invoice ID"]

            for group in allItems {
                if y > 720 {
                    context.beginPage()
                    y = 40
                }

                (group.operatorName as NSString).draw(at: CGPoint(x: 40, y: y), withAttributes: sectionAttrs)
                y += 20

                for (i, header) in headers.enumerated() {
                    (header as NSString).draw(at: CGPoint(x: colX[i], y: y), withAttributes: headerAttrs)
                }
                y += 16

                for item in group.items {
                    if y > 750 {
                        context.beginPage()
                        y = 40
                    }

                    let dateStr = item.createdAt.map { dateFormatter.string(from: $0) } ?? "--"
                    (dateStr as NSString).draw(at: CGPoint(x: colX[0], y: y), withAttributes: cellAttrs)
                    ("\(item.amountSats)" as NSString).draw(at: CGPoint(x: colX[1], y: y), withAttributes: cellAttrs)
                    let creditsStr = item.apiSatsCredited > 0 ? "\(item.apiSatsCredited)" : "--"
                    (creditsStr as NSString).draw(at: CGPoint(x: colX[2], y: y), withAttributes: cellAttrs)
                    (item.status as NSString).draw(at: CGPoint(x: colX[3], y: y), withAttributes: cellAttrs)

                    let truncId = item.id.count > 30 ? String(item.id.prefix(14)) + "..." + String(item.id.suffix(14)) : item.id
                    (truncId as NSString).draw(at: CGPoint(x: colX[4], y: y), withAttributes: idAttrs)
                    y += 14
                }

                y += 12
            }
        }

        let filename = "invoices-\(shortNpub).pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? data.write(to: url)
        exportItems = [url]
        showingShareSheet = true
    }

    // MARK: - Image

    private func exportImage() {
        let rowHeight: CGFloat = 18
        let headerHeight: CGFloat = 30
        let sectionGap: CGFloat = 24
        let titleHeight: CGFloat = 40
        let padding: CGFloat = 20
        let width: CGFloat = 700

        var totalHeight = titleHeight + padding * 2
        for group in allItems {
            totalHeight += headerHeight + sectionGap + CGFloat(group.items.count) * rowHeight + 12
        }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: totalHeight))
        let image = renderer.image { ctx in
            UIColor.systemBackground.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: totalHeight))

            var y = padding

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 14),
                .foregroundColor: UIColor.label
            ]
            let headerAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 9),
                .foregroundColor: UIColor.secondaryLabel
            ]
            let cellAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: UIColor.label
            ]
            let sectionAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 11),
                .foregroundColor: UIColor.label
            ]
            let idAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 7, weight: .regular),
                .foregroundColor: UIColor.secondaryLabel
            ]

            let title = "Invoice Report — \(shortNpub)"
            (title as NSString).draw(at: CGPoint(x: padding, y: y), withAttributes: titleAttrs)
            y += titleHeight

            let colX: [CGFloat] = [padding, 150, 220, 290, 360]
            let headers = ["Date", "Amount", "Credits", "Status", "Invoice ID"]

            for group in allItems {
                (group.operatorName as NSString).draw(at: CGPoint(x: padding, y: y), withAttributes: sectionAttrs)
                y += 18

                for (i, header) in headers.enumerated() {
                    (header as NSString).draw(at: CGPoint(x: colX[i], y: y), withAttributes: headerAttrs)
                }
                y += 14

                for item in group.items {
                    let dateStr = item.createdAt.map { dateFormatter.string(from: $0) } ?? "--"
                    (dateStr as NSString).draw(at: CGPoint(x: colX[0], y: y), withAttributes: cellAttrs)
                    ("\(item.amountSats)" as NSString).draw(at: CGPoint(x: colX[1], y: y), withAttributes: cellAttrs)
                    let creditsStr = item.apiSatsCredited > 0 ? "\(item.apiSatsCredited)" : "--"
                    (creditsStr as NSString).draw(at: CGPoint(x: colX[2], y: y), withAttributes: cellAttrs)
                    (item.status as NSString).draw(at: CGPoint(x: colX[3], y: y), withAttributes: cellAttrs)
                    let truncId = item.id.count > 40 ? String(item.id.prefix(18)) + "..." + String(item.id.suffix(18)) : item.id
                    (truncId as NSString).draw(at: CGPoint(x: colX[4], y: y), withAttributes: idAttrs)
                    y += rowHeight
                }

                y += 12
            }
        }

        exportItems = [image]
        showingShareSheet = true
    }

    private var shortNpub: String {
        if patronNpub.count > 16 {
            return String(patronNpub.prefix(12)) + "..." + String(patronNpub.suffix(4))
        }
        return patronNpub
    }
}

// MARK: - Share Sheet

private struct InvoiceShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
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
