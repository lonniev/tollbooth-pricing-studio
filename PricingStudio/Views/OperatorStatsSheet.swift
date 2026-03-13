import SwiftUI

struct OperatorStatsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let operator_: Operator
    let stats: OperatorStats?

    var body: some View {
        NavigationStack {
            Group {
                if let stats {
                    statsContent(stats)
                } else {
                    ProgressView("Loading operator details...")
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
            toolInventorySection(stats)
            if !stats.services.isEmpty {
                servicesSection(stats)
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
                        Text(service.type.uppercased())
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
}
