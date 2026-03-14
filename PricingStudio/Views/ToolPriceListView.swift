import SwiftUI

struct ToolPriceListView: View {
    let tools: [ToolPrice]
    var viewModel: PricingViewModel?
    var target: (any PricingTarget)?
    @State private var saveError: String?
    @State private var showSaveSuccess = false

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

                        if let target {
                            Button("Save to Operator") {
                                Task {
                                    do {
                                        try await viewModel.savePricing(for: target)
                                        showSaveSuccess = true
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                            showSaveSuccess = false
                                        }
                                    } catch {
                                        saveError = error.localizedDescription
                                    }
                                }
                            }
                            .font(.caption)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                        }

                        Button("Reset All") {
                            viewModel.resetAllEdits()
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }

                if showSaveSuccess {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
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
        .alert("Save Failed", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK") { saveError = nil }
        } message: {
            if let saveError {
                Text(saveError)
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
