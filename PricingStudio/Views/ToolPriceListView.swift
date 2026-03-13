import SwiftUI

struct ToolPriceListView: View {
    let tools: [ToolPrice]
    var viewModel: PricingViewModel?

    private var groupedTools: [(String, [ToolPrice])] {
        let groups = Dictionary(grouping: tools) { $0.category }
        let order = ["free", "auth", "read", "write", "heavy"]
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

                if let viewModel, viewModel.hasEdits {
                    HStack(spacing: 6) {
                        Text("\(viewModel.localEdits.count) edit\(viewModel.localEdits.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.blue)

                        Button("Reset All") {
                            viewModel.resetAllEdits()
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }

            ForEach(groupedTools, id: \.0) { category, categoryTools in
                VStack(alignment: .leading, spacing: 8) {
                    Text(categoryDisplayName(category))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    ForEach(categoryTools) { tool in
                        ToolPriceRow(tool: tool, viewModel: viewModel)
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
        default: return category.capitalized
        }
    }
}
