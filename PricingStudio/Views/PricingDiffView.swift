import SwiftUI

/// Side-by-side comparison of two pricing models (Plan A vs Plan B).
///
/// Shows tool-by-tool price differences, pipeline divergences, and a summary
/// of which model is cheaper/more expensive overall.
struct PricingDiffView: View {
    let modelA: PricingModelResponse
    let modelB: PricingModelResponse
    let labelA: String
    let labelB: String

    private var allToolNames: [String] {
        var names = Set<String>()
        for tool in modelA.tools ?? [] { names.insert(tool.toolName) }
        for tool in modelB.tools ?? [] { names.insert(tool.toolName) }
        return names.sorted()
    }

    private var summaryStats: (cheaper: String, totalA: Int, totalB: Int, delta: Int) {
        let a = (modelA.tools ?? []).reduce(0) { $0 + $1.priceSats }
        let b = (modelB.tools ?? []).reduce(0) { $0 + $1.priceSats }
        let delta = b - a
        let label = delta > 0 ? labelA : delta < 0 ? labelB : "Tie"
        return (label, a, b, abs(delta))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                summaryHeader
                toolComparisonSection
                pipelineComparisonSection
            }
            .padding()
        }
        .navigationTitle("Model Comparison")
    }

    // MARK: - Summary

    @ViewBuilder
    private var summaryHeader: some View {
        let stats = summaryStats
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                modelBadge(labelA, color: .blue)
                    .accessibilityIdentifier("diffModelALabel")
                Text("vs")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                modelBadge(labelB, color: .orange)
                    .accessibilityIdentifier("diffModelBLabel")
            }

            HStack(spacing: 24) {
                VStack(alignment: .leading) {
                    Text("Total Cost")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        costLabel(stats.totalA, label: labelA, color: .blue)
                        costLabel(stats.totalB, label: labelB, color: .orange)
                    }
                }
                Spacer()
                if stats.delta > 0 {
                    VStack(alignment: .trailing) {
                        Text("Cheaper by \(stats.delta) sats")
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                        Text(stats.cheaper)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func modelBadge(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.subheadline.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func costLabel(_ sats: Int, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(sats) sats")
                .font(.title3.bold().monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(color)
        }
    }

    // MARK: - Tool Comparison

    @ViewBuilder
    private var toolComparisonSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tool Prices")
                .font(.title3.bold())

            let toolsA = Dictionary(uniqueKeysWithValues: (modelA.tools ?? []).map { ($0.toolName, $0) })
            let toolsB = Dictionary(uniqueKeysWithValues: (modelB.tools ?? []).map { ($0.toolName, $0) })

            ForEach(allToolNames, id: \.self) { name in
                let priceA = toolsA[name]
                let priceB = toolsB[name]
                toolDiffRow(name: name, a: priceA, b: priceB)
            }
        }
    }

    @ViewBuilder
    private func toolDiffRow(name: String, a: ToolPrice?, b: ToolPrice?) -> some View {
        let satsA = a?.priceSats ?? 0
        let satsB = b?.priceSats ?? 0
        let delta = satsB - satsA
        let isNew = a == nil && b != nil
        let isRemoved = a != nil && b == nil

        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if isNew {
                        Text("NEW")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.green, in: Capsule())
                    }
                    if isRemoved {
                        Text("REMOVED")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.red, in: Capsule())
                    }
                    Text(name)
                        .font(.caption)
                        .lineLimit(1)
                        .strikethrough(isRemoved)
                        .foregroundStyle(isRemoved ? .secondary : .primary)
                }
                if let cat = a?.category ?? b?.category, !cat.isEmpty {
                    Text(cat)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(satsA)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.blue)
                .frame(width: 60, alignment: .trailing)

            Text("\(satsB)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.orange)
                .frame(width: 60, alignment: .trailing)

            deltaIndicator(delta)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            isNew ? Color.green.opacity(0.05) :
            isRemoved ? Color.red.opacity(0.05) :
            delta != 0 ? Color.yellow.opacity(0.05) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    @ViewBuilder
    private func deltaIndicator(_ delta: Int) -> some View {
        if delta == 0 {
            Text("—")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 2) {
                Image(systemName: delta > 0 ? "arrow.up" : "arrow.down")
                    .font(.caption2)
                Text("\(abs(delta))")
                    .font(.caption.monospacedDigit())
            }
            .foregroundStyle(delta > 0 ? .red : .green)
        }
    }

    // MARK: - Per-tool Chain Comparison

    @ViewBuilder
    private var pipelineComparisonSection: some View {
        // Build a unified list of (toolId → chainA, chainB) so we can
        // diff each tool side-by-side.  Tools that have a chain on
        // either side appear; tools with no chains on both sides are
        // omitted.
        let a = Dictionary(uniqueKeysWithValues:
            (modelA.tools ?? []).map { ($0.toolId, $0) }
        )
        let b = Dictionary(uniqueKeysWithValues:
            (modelB.tools ?? []).map { ($0.toolId, $0) }
        )
        let allIds = Set(a.keys).union(b.keys)
        let withChains = allIds.filter { (a[$0]?.chain.isEmpty ?? true) == false || (b[$0]?.chain.isEmpty ?? true) == false }

        if withChains.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("Constraint Chains (per tool)")
                    .font(.title3.bold())

                ForEach(Array(withChains).sorted(), id: \.self) { toolId in
                    let tool = a[toolId] ?? b[toolId]
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tool?.toolName ?? "(unknown)")
                            .font(.subheadline.bold())
                        HStack(alignment: .top, spacing: 16) {
                            pipelineColumn(steps: a[toolId]?.chain ?? [], label: labelA, color: .blue)
                            Divider()
                            pipelineColumn(steps: b[toolId]?.chain ?? [], label: labelB, color: .orange)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func pipelineColumn(steps: [PipelineStep], label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(color)

            if steps.isEmpty {
                Text("No constraints")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(steps) { step in
                    HStack(spacing: 6) {
                        Image(systemName: step.displayType.iconName)
                            .font(.caption)
                            .foregroundStyle(color)
                        Text(step.displayType.displayName)
                            .font(.caption)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
