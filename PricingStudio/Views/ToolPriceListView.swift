import SwiftUI

struct ToolPriceListView: View {
    let tools: [ToolPrice]
    var viewModel: PricingViewModel?
    var target: (any PricingTarget)?

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

                if let viewModel, !viewModel.localEdits.isEmpty {
                    let n = viewModel.localEdits.count
                    Text("\(n) tool \(n == 1 ? "edit" : "edits")")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }

            ForEach(groupedTools, id: \.0) { category, categoryTools in
                VStack(alignment: .leading, spacing: 8) {
                    Text(categoryDisplayName(category))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    ForEach(categoryTools) { tool in
                        let isRemoved = viewModel?.localRemovals.contains(tool.toolName) ?? false
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
                            ToolPriceRow(tool: tool, viewModel: viewModel)
                        }
                    }
                }
            }
        }
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
