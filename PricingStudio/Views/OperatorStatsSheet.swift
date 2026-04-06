import SwiftUI

struct OperatorStatsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let operator_: Operator
    let stats: OperatorStats?

    @State private var fetchedStats: OperatorStats?
    @State private var fetchError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let s = stats ?? fetchedStats {
                    statsContent(s)
                } else if let err = fetchError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text(err)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    ProgressView("Loading operator details...")
                        .task { await loadStats() }
                }
            }
            .navigationTitle(operator_.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func statsContent(_ stats: OperatorStats) -> some View {
        List {
            registrySection(stats)
            if let versions = stats.versions, !versions.isEmpty {
                buildInfoSection(versions)
            }
            toolInventorySection(stats)
            if !stats.services.isEmpty {
                servicesSection(stats)
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
            Text(operator_.npub)
                .font(.caption)
                .monospaced()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
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
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Fetch

    private let oauthService = OAuthService()

    private func loadStats() async {
        let mcpService = MCPService()
        do {
            // Resolve Oracle URL and authenticate (same pattern as PricingViewModel)
            let oracleURL = try await mcpService.resolveOracleURL(
                forOperator: operator_.npub
            )
            let oracleHost = oracleURL.host ?? "oracle"
            let oracleToken = try await resolveToken(for: oracleURL, host: oracleHost)

            // Lookup member from Oracle
            let member = try await mcpService.lookupOperator(
                npub: operator_.npub,
                onStep: { _ in }
            )

            // Build tool stats from pricing model if endpoint available
            var totalTools = 0
            var freeTools = 0
            var paidTools = 0
            var categories: [String: (count: Int, min: Int, max: Int)] = [:]

            if let urlStr = operator_.mcpEndpointURL,
               let endpoint = URL(string: urlStr) {
                let host = endpoint.host ?? operator_.npub
                let token = try await resolveToken(for: endpoint, host: host)

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
                let host = endpoint.host ?? operator_.npub
                let token = try await resolveToken(for: endpoint, host: host)
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

    /// Standard Horizon OAuth token resolution — same as PricingViewModel.
    private func resolveToken(for endpoint: URL, host: String) async throws -> String {
        if let bundle = KeychainService.loadTokenBundle(forOperator: host) {
            if !bundle.isExpired { return bundle.accessToken }
            if bundle.refreshToken != nil {
                if let refreshed = try? await oauthService.refresh(bundle: bundle) {
                    try? KeychainService.saveTokenBundle(refreshed, forOperator: host)
                    return refreshed.accessToken
                }
            }
            KeychainService.deleteTokenBundle(forOperator: host)
        }
        let bundle = try await oauthService.authenticate(mcpEndpoint: endpoint)
        try KeychainService.saveTokenBundle(bundle, forOperator: host)
        return bundle.accessToken
    }
}
