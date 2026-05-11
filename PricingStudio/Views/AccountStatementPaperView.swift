import SwiftUI

/// Receipt-style rendering of the free JSON account statement.
///
/// Used as the fallback when a patron can't afford the paid infographic.
/// Renders summary, active tranches, tools used, and invoices paid as a
/// monospaced "paper printout" so the patron still gets a usable record.
struct AccountStatementPaperView: View {
    let patronName: String
    let patronNpub: String
    let operatorName: String
    let statement: MCPService.AccountStatementResult

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                divider
                summaryBlock
                divider
                tranchesBlock
                divider
                toolsBlock
                divider
                invoicesBlock
                divider
                footer
            }
            .font(.system(size: 13, design: .monospaced))
            .padding(20)
        }
        .background(Color(uiColor: .systemBackground))
        .overlay(receiptBackground)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text("ACCOUNT STATEMENT")
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    .tracking(2.0)
                Spacer()
                ShareLink(item: plainText(),
                          preview: SharePreview("Account Statement — \(operatorName)")) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(6)
                }
                .accessibilityLabel("Share or copy statement as text")
            }
            kv("Patron", patronName)
            kv("Npub", String(patronNpub.prefix(20)) + "…")
            kv("Operator", operatorName)
            if let when = statement.generatedAt {
                kv("Generated", when.formatted(date: .abbreviated, time: .shortened))
            }
            if let period = statement.statementPeriodDays {
                kv("Period", "Last \(period) days")
            }
        }
    }

    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("SUMMARY")
            if let s = statement.summary {
                kvRight("Balance",    "\(s.balanceApiSats.formatted()) sats", emphasize: true)
                kvRight("Deposited",  "\(s.totalDepositedApiSats.formatted()) sats")
                kvRight("Consumed",   "\(s.totalConsumedApiSats.formatted()) sats")
                kvRight("Expired",    "\(s.totalExpiredApiSats.formatted()) sats")
                kvRight("Net",        netLine(s))
            } else {
                Text("(no summary available)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var tranchesBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("ACTIVE TRANCHES")
            if statement.activeTranches.isEmpty {
                Text("(none)").foregroundStyle(.secondary)
            } else {
                ForEach(statement.activeTranches) { t in
                    trancheRow(t)
                }
            }
        }
    }

    private var toolsBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("TOOLS USED")
            if statement.toolUsage.isEmpty {
                Text("(no usage recorded)").foregroundStyle(.secondary)
            } else {
                let totalCalls = statement.toolUsage.reduce(0) { $0 + $1.calls }
                let totalSats = statement.toolUsage.reduce(0) { $0 + $1.apiSats }
                let anyAveraged = statement.toolUsage.contains { $0.calls > 0 && $0.apiSats % $0.calls != 0 }

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 2) {
                    // Column headers
                    GridRow {
                        Text("Item")
                            .columnHeader()
                        Text("Qty")
                            .columnHeader()
                            .gridColumnAlignment(.trailing)
                        Text("Sats / call")
                            .columnHeader()
                            .gridColumnAlignment(.trailing)
                        Text("Line total")
                            .columnHeader()
                            .gridColumnAlignment(.trailing)
                    }
                    Divider().gridCellColumns(4)

                    // Rows
                    ForEach(statement.toolUsage) { stat in
                        GridRow {
                            Text(stat.tool)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(stat.calls)")
                                .gridColumnAlignment(.trailing)
                            Text(unitPriceDisplay(calls: stat.calls, sats: stat.apiSats))
                                .gridColumnAlignment(.trailing)
                                .foregroundStyle(.secondary)
                            Text("\(stat.apiSats)")
                                .gridColumnAlignment(.trailing)
                        }
                    }

                    Divider().gridCellColumns(4)

                    // Totals row
                    GridRow {
                        Text("Totals")
                            .fontWeight(.bold)
                        Text("\(totalCalls)")
                            .fontWeight(.bold)
                            .gridColumnAlignment(.trailing)
                        Text("—")
                            .foregroundStyle(.tertiary)
                            .gridColumnAlignment(.trailing)
                        Text("\(totalSats) sats")
                            .fontWeight(.bold)
                            .gridColumnAlignment(.trailing)
                    }
                }

                // Small print: explain when the unit price is misleading
                Text(anyAveraged
                     ? "Note — Sats / call is the period average (line total ÷ calls). For tools with fractional averages shown, the per-call price varied during the period; if the operator changed the price mid-statement the simple math (calls × sats per call) won't reproduce the line total exactly."
                     : "Note — Sats / call reflects the simple line total ÷ calls. If the operator changed a tool's price during this statement period, that simple math won't generally hold; this snapshot is accurate only when per-tool pricing was stable for the whole period.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var invoicesBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("INVOICES")
            if statement.invoiceItems.isEmpty {
                Text("(none)").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 2) {
                    GridRow {
                        Text("Date").columnHeader()
                        Text("Status").columnHeader()
                        Text("Sats paid").columnHeader().gridColumnAlignment(.trailing)
                        Text("Credited").columnHeader().gridColumnAlignment(.trailing)
                    }
                    Divider().gridCellColumns(4)
                    ForEach(statement.invoiceItems) { item in
                        GridRow {
                            Text(item.createdAt?.formatted(date: .numeric, time: .omitted) ?? "—")
                            Text(item.status.uppercased())
                                .foregroundStyle(statusColor(item.status))
                            Text("\(item.amountSats)")
                                .gridColumnAlignment(.trailing)
                            Text("\(item.apiSatsCredited)")
                                .gridColumnAlignment(.trailing)
                                .foregroundStyle(item.apiSatsCredited == 0 ? .tertiary : .primary)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .center, spacing: 6) {
            Text("--- end of statement ---")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("dpyc.community")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .tracking(1.5)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Rows

    private func trancheRow(_ t: MCPService.ActiveTranche) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(t.remainingSats.formatted()) / \(t.originalSats.formatted()) sats")
                if let granted = t.grantedAt {
                    Text("granted \(granted.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let expires = t.expiresAt {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("expires")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(expires.formatted(date: .abbreviated, time: .omitted))
                        .foregroundStyle(expires < Date() ? .red : .primary)
                }
            }
        }
        .padding(.vertical, 1)
    }

    /// Period-average sats per call, computed as line total ÷ calls.
    /// Whole numbers render as-is; fractional values render to 2 decimals
    /// with a leading "~" to signal the average is approximate.
    private func unitPriceDisplay(calls: Int, sats: Int) -> String {
        guard calls > 0 else { return "—" }
        if sats % calls == 0 {
            return "\(sats / calls)"
        } else {
            return String(format: "~%.2f", Double(sats) / Double(calls))
        }
    }

    private func invoiceRow(_ item: MCPService.InvoiceLineItem) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.createdAt?.formatted(date: .abbreviated, time: .omitted) ?? "—")
                Text(String(item.id.prefix(12)) + "…")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(item.amountSats.formatted()) sats")
                Text(item.status.uppercased())
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(statusColor(item.status))
            }
        }
        .padding(.vertical, 1)
    }

    // MARK: - Helpers

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .tracking(2.0)
            .foregroundStyle(.secondary)
    }

    private func kv(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(key + ":")
                .frame(width: 90, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func kvRight(_ key: String, _ value: String, emphasize: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(emphasize ? .bold : .regular)
        }
    }

    private var divider: some View {
        Text(String(repeating: "─", count: 38))
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Faint receipt-paper tint — subtle off-white wash so it doesn't shout
    /// against the rest of the app, but reads as a printed document.
    private var receiptBackground: some View {
        Color(red: 1.0, green: 0.99, blue: 0.95)
            .opacity(0.35)
            .allowsHitTesting(false)
    }

    private func netLine(_ s: MCPService.AccountSummary) -> String {
        let net = s.totalDepositedApiSats - s.totalConsumedApiSats - s.totalExpiredApiSats
        return "\(net.formatted()) sats  (= deposited − consumed − expired)"
    }

    private func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "settled": return .green
        case "expired", "invalid": return .red
        case "pending": return .orange
        default: return .secondary
        }
    }

    // MARK: - Plain-text rendering (for ShareLink)

    /// Produce a fixed-width text rendering of the same statement so the
    /// patron can paste it into a note, email, or Nostr DM. Pure ASCII so
    /// it survives copy/paste through any client.
    ///
    /// Uses Swift-native string padding rather than `String(format:)`; the
    /// `%s` format specifier expects a C string (`UnsafePointer<CChar>`),
    /// not a Swift `String`, and passing the latter crashes with
    /// `EXC_BAD_ACCESS` at runtime.
    func plainText() -> String {
        var lines: [String] = []
        lines.append("ACCOUNT STATEMENT")
        lines.append("Patron:    \(patronName)")
        lines.append("Npub:      \(patronNpub.prefix(20))…")
        lines.append("Operator:  \(operatorName)")
        if let when = statement.generatedAt {
            lines.append("Generated: \(when.formatted(date: .abbreviated, time: .shortened))")
        }
        if let period = statement.statementPeriodDays {
            lines.append("Period:    Last \(period) days")
        }
        lines.append("")
        lines.append(String(repeating: "-", count: 56))

        if let s = statement.summary {
            lines.append("SUMMARY")
            lines.append("  Balance:    \(s.balanceApiSats.formatted()) sats")
            lines.append("  Deposited:  \(s.totalDepositedApiSats.formatted()) sats")
            lines.append("  Consumed:   \(s.totalConsumedApiSats.formatted()) sats")
            lines.append("  Expired:    \(s.totalExpiredApiSats.formatted()) sats")
            let net = s.totalDepositedApiSats - s.totalConsumedApiSats - s.totalExpiredApiSats
            lines.append("  Net:        \(net.formatted()) sats  (= deposited - consumed - expired)")
            lines.append("")
            lines.append(String(repeating: "-", count: 56))
        }

        if !statement.activeTranches.isEmpty {
            lines.append("ACTIVE TRANCHES")
            for t in statement.activeTranches {
                let granted = t.grantedAt?.formatted(date: .abbreviated, time: .omitted) ?? "—"
                let expires = t.expiresAt?.formatted(date: .abbreviated, time: .omitted) ?? "—"
                lines.append("  \(t.remainingSats)/\(t.originalSats) sats   granted \(granted)   expires \(expires)")
            }
            lines.append("")
            lines.append(String(repeating: "-", count: 56))
        }

        if !statement.toolUsage.isEmpty {
            lines.append("TOOLS USED")
            // Column widths: Item 36, Qty 5, Sats/call 12, Total 8
            lines.append("  "
                         + leftPad("Item", to: 36) + " "
                         + rightPad("Qty", to: 5) + " "
                         + rightPad("Sats / call", to: 12) + " "
                         + rightPad("Total", to: 8))
            lines.append("  " + String(repeating: "-", count: 64))
            for stat in statement.toolUsage {
                let name = stat.tool.count > 36
                    ? String(stat.tool.prefix(33)) + "..."
                    : stat.tool
                lines.append("  "
                             + leftPad(name, to: 36) + " "
                             + rightPad("\(stat.calls)", to: 5) + " "
                             + rightPad(unitPriceDisplay(calls: stat.calls, sats: stat.apiSats), to: 12) + " "
                             + rightPad("\(stat.apiSats)", to: 8))
            }
            let totalCalls = statement.toolUsage.reduce(0) { $0 + $1.calls }
            let totalSats = statement.toolUsage.reduce(0) { $0 + $1.apiSats }
            lines.append("  " + String(repeating: "-", count: 64))
            lines.append("  "
                         + leftPad("Totals", to: 36) + " "
                         + rightPad("\(totalCalls)", to: 5) + " "
                         + rightPad("—", to: 12) + " "
                         + rightPad("\(totalSats)", to: 8))
            lines.append("")
            lines.append("  Note — Sats/call is the period average (line total / calls).")
            lines.append("  If the operator changed a tool's price during this period, simple")
            lines.append("  math (calls × sats/call) won't reproduce the line total exactly.")
            lines.append("")
            lines.append(String(repeating: "-", count: 56))
        }

        if !statement.invoiceItems.isEmpty {
            lines.append("INVOICES")
            lines.append("  "
                         + leftPad("Date", to: 12) + " "
                         + leftPad("Status", to: 10) + " "
                         + rightPad("Sats paid", to: 10) + " "
                         + rightPad("Credited", to: 10))
            lines.append("  " + String(repeating: "-", count: 50))
            for item in statement.invoiceItems {
                let date = item.createdAt?.formatted(date: .numeric, time: .omitted) ?? "—"
                lines.append("  "
                             + leftPad(date, to: 12) + " "
                             + leftPad(item.status, to: 10) + " "
                             + rightPad("\(item.amountSats)", to: 10) + " "
                             + rightPad("\(item.apiSatsCredited)", to: 10))
            }
            lines.append("")
            lines.append(String(repeating: "-", count: 56))
        }

        lines.append("")
        lines.append("--- end of statement ---")
        lines.append("dpyc.community")
        return lines.joined(separator: "\n")
    }

    /// Left-aligned padding: pad spaces to the right of the string to reach
    /// `width`. Truncates if the string is already wider.
    private func leftPad(_ s: String, to width: Int) -> String {
        if s.count >= width { return String(s.prefix(width)) }
        return s + String(repeating: " ", count: width - s.count)
    }

    /// Right-aligned padding: pad spaces to the left of the string.
    /// Truncates if the string is already wider.
    private func rightPad(_ s: String, to width: Int) -> String {
        if s.count >= width { return String(s.prefix(width)) }
        return String(repeating: " ", count: width - s.count) + s
    }
}

private extension View {
    /// Style used for column-header labels in the Grid-backed sections.
    func columnHeader() -> some View {
        self.font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(1.5)
            .foregroundStyle(.secondary)
    }
}
