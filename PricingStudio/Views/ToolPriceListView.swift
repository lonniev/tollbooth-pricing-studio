import SwiftUI

struct ToolPriceListView: View {
    let tools: [ToolPrice]

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
            Text("Tool Prices")
                .font(.title3.bold())

            ForEach(groupedTools, id: \.0) { category, categoryTools in
                VStack(alignment: .leading, spacing: 8) {
                    Text(categoryDisplayName(category))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    ForEach(categoryTools) { tool in
                        ToolPriceRow(tool: tool)
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
