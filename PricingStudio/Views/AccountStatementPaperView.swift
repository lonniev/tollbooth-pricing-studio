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
            Text("ACCOUNT STATEMENT")
                .font(.system(size: 17, weight: .bold, design: .monospaced))
                .tracking(2.0)
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
                ForEach(statement.toolUsage) { stat in
                    toolRow(stat)
                }
                let totalCalls = statement.toolUsage.reduce(0) { $0 + $1.calls }
                let totalSats = statement.toolUsage.reduce(0) { $0 + $1.apiSats }
                Divider().padding(.vertical, 2)
                kvRight("Totals",
                        "\(totalCalls.formatted()) calls / \(totalSats.formatted()) sats",
                        emphasize: true)
            }
        }
    }

    private var invoicesBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("INVOICES")
            if statement.invoiceItems.isEmpty {
                Text("(none)").foregroundStyle(.secondary)
            } else {
                ForEach(statement.invoiceItems) { item in
                    invoiceRow(item)
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

    private func toolRow(_ stat: MCPService.ToolUsageStat) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(stat.tool)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("\(stat.calls) × — \(stat.apiSats) sats")
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 1)
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
}
