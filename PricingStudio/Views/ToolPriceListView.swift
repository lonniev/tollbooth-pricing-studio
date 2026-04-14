import SwiftUI

struct ToolPriceListView: View {
    let tools: [ToolPrice]
    var viewModel: PricingViewModel?
    var target: (any PricingTarget)?

    @State private var selectedToolIds: Set<String> = []
    @State private var batchSats: String = ""
    @State private var batchType: PriceType = .flat
    @State private var batchCategory: String = ""

    private var groupedTools: [(String, [ToolPrice])] {
        let groups = Dictionary(grouping: tools) { $0.category }
        let order = ["free", "auth", "read", "write", "heavy", "restricted"]
        return order.compactMap { key in
            guard let items = groups[key] else { return nil }
            return (key, items.sorted { $0.toolName < $1.toolName })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Tool Prices")
                    .font(.title3.bold())

                Spacer()

                if !selectedToolIds.isEmpty {
                    Text("\(selectedToolIds.count) selected")
                        .font(.caption.bold())
                        .foregroundStyle(.blue)
                    Button("Clear") { selectedToolIds.removeAll() }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                } else if let viewModel, !viewModel.localEdits.isEmpty {
                    let n = viewModel.localEdits.count
                    Text("\(n) tool \(n == 1 ? "edit" : "edits")")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }

            // Batch edit bar — visible when tools are selected
            if !selectedToolIds.isEmpty, let viewModel {
                batchEditBar(viewModel: viewModel)
            }

            ForEach(groupedTools, id: \.0) { category, categoryTools in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(categoryDisplayName(category))
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Spacer()
                        // Select/deselect all in category
                        let allInCategory = Set(categoryTools.map(\.toolId))
                        let allSelected = allInCategory.isSubset(of: selectedToolIds)
                        Button(allSelected ? "Deselect" : "Select All") {
                            if allSelected {
                                selectedToolIds.subtract(allInCategory)
                            } else {
                                selectedToolIds.formUnion(allInCategory)
                            }
                        }
                        .font(.caption2)
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                    }

                    ForEach(categoryTools) { tool in
                        let isRemoved = viewModel?.localRemovals.contains(tool.toolId) ?? false
                        if isRemoved {
                            HStack(spacing: 12) {
                                Text(tool.toolName)
                                    .font(.subheadline.monospaced())
                                    .strikethrough()
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("REMOVED")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.red, in: Capsule())
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 12)
                            .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                            .opacity(0.5)
                        } else {
                            HStack(spacing: 8) {
                                Image(systemName: selectedToolIds.contains(tool.toolId) ? "checkmark.circle.fill" : "circle")
                                    .font(.subheadline)
                                    .foregroundStyle(selectedToolIds.contains(tool.toolId) ? Color.blue : Color.gray.opacity(0.3))
                                    .onTapGesture {
                                        if selectedToolIds.contains(tool.toolId) {
                                            selectedToolIds.remove(tool.toolId)
                                        } else {
                                            selectedToolIds.insert(tool.toolId)
                                        }
                                    }
                                ToolPriceRow(tool: tool, viewModel: viewModel, target: target,
                                             selectedToolIds: selectedToolIds, allTools: tools)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func batchEditBar(viewModel: PricingViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Batch Edit \(selectedToolIds.count) tools")
                .font(.caption.bold())
                .foregroundStyle(.blue)

            HStack(spacing: 8) {
                Picker("Type", selection: $batchType) {
                    Text("Flat").tag(PriceType.flat)
                    Text("Ad Valorem").tag(PriceType.percent)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)

                TextField(batchType == .flat ? "sats" : "percent", text: $batchSats)
                    .font(.caption.monospaced())
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .keyboardType(.numberPad)

                Button("Apply") {
                    let sats = Int(batchSats) ?? 0
                    for toolId in selectedToolIds {
                        if let tool = tools.first(where: { $0.toolId == toolId }) {
                            viewModel.applyEdit(
                                toolName: tool.toolName,
                                priceSats: sats,
                                priceType: batchType,
                                priceFormula: batchType == .percent ? "amount_sats" : nil
                            )
                        }
                    }
                    selectedToolIds.removeAll()
                    batchSats = ""
                }
                .font(.caption.bold())
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(batchSats.isEmpty)

                Button("FREE") {
                    for toolId in selectedToolIds {
                        if let tool = tools.first(where: { $0.toolId == toolId }) {
                            viewModel.applyEdit(
                                toolName: tool.toolName,
                                priceSats: 0,
                                priceType: .flat,
                                priceFormula: nil
                            )
                        }
                    }
                    selectedToolIds.removeAll()
                }
                .font(.caption.bold())
                .buttonStyle(.bordered)
                .tint(.green)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.blue.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func categoryDisplayName(_ category: String) -> String {
        switch category {
        case "free": return "Free"
        case "auth": return "Auth & Balance"
        case "read": return "Read (1 sat)"
        case "write": return "Write (5 sats)"
        case "heavy": return "Heavy (10 sats)"
        case "restricted": return "Restricted (Operator Only)"
        default: return category.capitalized
        }
    }
}
