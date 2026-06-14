import SwiftUI
import UIKit

struct OperatorStatsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let operator_: Operator
    let stats: OperatorStats?

    @State private var fetchedStats: OperatorStats?
    @State private var fetchError: String?

    var body: some View {
        NavigationStack {
            List {
                // Locally-known identity — shown IMMEDIATELY, no remote fetch.
                // Lets you read and copy the MCP URL / npub without waiting on
                // the live-stats round-trips below.
                connectionSection()

                if let s = stats ?? fetchedStats {
                    registrySection(s)
                    if let versions = s.versions, !versions.isEmpty {
                        buildInfoSection(versions)
                    }
                    toolInventorySection(s)
                    if !s.services.isEmpty {
                        servicesSection(s)
                    }
                } else if let err = fetchError {
                    Section("Live Details") {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Live Details") {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Loading from operator's MCP…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(operator_.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                // Only the live sections need a fetch; the connection section is
                // already on screen. Skip if stats were supplied by the caller.
                if stats == nil && fetchedStats == nil && fetchError == nil {
                    await loadStats()
                }
            }
        }
    }

    /// Identity the app already holds locally — rendered without any MCP call so
    /// the MCP URL is visible and copyable the instant the sheet opens.
    @ViewBuilder
    private func connectionSection() -> some View {
        Section("Connection") {
            if let urlStr = operator_.mcpEndpointURL, !urlStr.isEmpty {
                copyableRow(label: "MCP URL", value: urlStr)
            }
            copyableRow(label: "npub", value: operator_.npub)
        }
    }

    /// A label + monospaced value that can be long-pressed to select, plus a
    /// context-menu Copy that puts the FULL (untruncated) value on the clipboard.
    private func copyableRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(.caption)
                .monospaced()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .contextMenu {
            Button {
                UIPasteboard.general.string = value
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }

    private func buildInfoSection(_ versions: [String: String]) -> some View {
        Section("Build") {
            ForEach(
                versions.sorted(by: { $0.key < $1.key }),
                id: \.key
            ) { key, value in
                LabeledContent(
                    key.replacingOccurrences(of: "_", with: " ").capitalized,
                    value: value
                )
                .font(.caption)
                .monospaced()
            }
        }
    }

    private func registrySection(_ stats: OperatorStats) -> some View {
        Section("Registry") {
            LabeledContent("Display Name", value: stats.registryDisplayName)
            HStack {
                Text("Role")
                Spacer()
                Text(stats.registryRole.capitalized)
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.blue.opacity(0.15), in: Capsule())
            }
            HStack {
                Text("Status")
                Spacer()
                Text(stats.registryStatus.capitalized)
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        stats.registryStatus == "active"
                            ? Color.green.opacity(0.15)
                            : Color.orange.opacity(0.15),
                        in: Capsule()
                    )
            }
            // npub lives in the always-visible Connection section above.
        }
    }

    private func toolInventorySection(_ stats: OperatorStats) -> some View {
        Section("Tool Inventory") {
            LabeledContent("Total Tools", value: "\(stats.totalToolCount)")
            LabeledContent("Free Tools", value: "\(stats.freeToolCount)")
            LabeledContent("Paid Tools", value: "\(stats.paidToolCount)")

            if !stats.categorySummaries.isEmpty {
                ForEach(stats.categorySummaries) { summary in
                    HStack {
                        Text(summary.category.capitalized)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(summary.count) tool\(summary.count == 1 ? "" : "s")")
                        if summary.minPriceSats > 0 {
                            Text("\(summary.minPriceSats)–\(summary.maxPriceSats) sat\(summary.maxPriceSats == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    private func servicesSection(_ stats: OperatorStats) -> some View {
        Section("Services") {
            ForEach(stats.services, id: \.name) { service in
                VStack(alignment: .leading, spacing: 4) {
                    Text(service.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    HStack(spacing: 6) {
                        Text("MCP")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                        Text(service.url)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = service.url
                    } label: {
                        Label("Copy URL", systemImage: "doc.on.doc")
                    }
                }
            }
        }
    }

    // MARK: - Fetch

    private func loadStats() async {
        let mcpService = MCPService()
        do {
            _ = try await mcpService.resolveOracleURL(
                forOperator: operator_.npub
            )

            let member = try await mcpService.lookupOperator(
                npub: operator_.npub,
                onStep: { _ in }
            )

            var totalTools = 0
            var freeTools = 0
            var paidTools = 0
            var categories: [String: (count: Int, min: Int, max: Int)] = [:]

            if let urlStr = operator_.mcpEndpointURL,
               let endpoint = URL(string: urlStr) {
                let model = try await mcpService.fetchPricingModel(
                    endpointURL: endpoint,
                    onStep: { _ in }
                )
                for tool in model.tools ?? [] {
                    totalTools += 1
                    if tool.priceSats == 0 {
                        freeTools += 1
                    } else {
                        paidTools += 1
                    }
                    let cat = tool.category.isEmpty ? "uncategorized" : tool.category
                    let existing = categories[cat, default: (0, Int.max, 0)]
                    categories[cat] = (
                        existing.count + 1,
                        min(existing.min, tool.priceSats),
                        max(existing.max, tool.priceSats)
                    )
                }
            }

            let summaries = categories.map { key, val in
                ToolCategorySummary(
                    category: key,
                    count: val.count,
                    minPriceSats: val.min == Int.max ? 0 : val.min,
                    maxPriceSats: val.max
                )
            }.sorted { $0.category < $1.category }

            // Fetch build info from service_status
            var versions: [String: String]?
            if let urlStr = operator_.mcpEndpointURL,
               let endpoint = URL(string: urlStr) {
                versions = try? await mcpService.callServiceStatus(
                    endpointURL: endpoint
                )
            }

            fetchedStats = OperatorStats(
                registryRole: member.role,
                registryStatus: member.status,
                registryDisplayName: member.displayName,
                services: member.services ?? [],
                totalToolCount: totalTools,
                freeToolCount: freeTools,
                paidToolCount: paidTools,
                categorySummaries: summaries,
                versions: versions,
                fetchedAt: Date()
            )
        } catch {
            fetchError = error.localizedDescription
        }
    }

}
