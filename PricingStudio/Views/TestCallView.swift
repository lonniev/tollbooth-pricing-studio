import SwiftUI
import SwiftData

/// Dry-run tool call simulation — pick operator, tool, identity, check affordability, execute.
struct TestCallView: View {
    @State private var vm = TestCallViewModel()
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Operator.addedAt) private var operators: [Operator]
    @Query(sort: \Patron.addedAt) private var patrons: [Patron]

    /// Pre-selected operator (when launched from operator detail or tool row).
    var preselectedOperator: Operator?
    /// Pre-selected tool (when launched from a specific tool row long-press).
    var preselectedTool: ToolPrice?

    /// When both operator and tool are pre-selected, lead with identity + execute.
    private var isDirectMode: Bool { preselectedOperator != nil && preselectedTool != nil }

    var body: some View {
        NavigationStack {
            Form {
                if isDirectMode {
                    // Direct mode: identity first, then execute, then details
                    identitySection
                    actionSection
                    resultSection
                    toolSummarySection
                    operatorSection
                    if !vm.availableTools.isEmpty { toolSection }
                } else {
                    // Browse mode: operator → tool → identity → execute
                    operatorSection
                    if !vm.availableTools.isEmpty { toolSection }
                    if vm.selectedTool != nil { identitySection }
                    actionSection
                    resultSection
                }
            }
            .navigationTitle(isDirectMode ? (vm.selectedTool?.toolName ?? "Test Call") : "Test Call")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if let op = preselectedOperator, vm.selectedOperator == nil {
                    vm.selectedOperator = op
                    await vm.loadTools()
                    if let tool = preselectedTool {
                        vm.selectedTool = vm.availableTools.first(where: { $0.toolName == tool.toolName }) ?? tool
                    }
                }
            }
        }
    }

    // MARK: - Tool Summary (direct mode)

    @ViewBuilder
    private var toolSummarySection: some View {
        if let tool = vm.selectedTool {
            Section("Tool") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tool.toolName)
                        .font(.subheadline.monospaced().bold())
                    if !tool.intent.isEmpty {
                        Text(tool.intent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Cost:")
                        Text("\(tool.priceSats) sats")
                            .bold()
                            .foregroundStyle(tool.priceSats == 0 ? .green : .orange)
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var operatorSection: some View {
        Section("Operator") {
            let mcpOperators = operators.filter { $0.mcpEndpointURL != nil && !$0.mcpEndpointURL!.isEmpty }
            if mcpOperators.isEmpty {
                Text("No operators with MCP endpoints")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(mcpOperators) { op in
                    Button {
                        vm.selectedOperator = op
                        Task { await vm.loadTools() }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(op.displayName).font(.headline)
                                Text(String(op.npub.prefix(16)) + "…")
                                    .font(.caption).monospaced()
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if vm.selectedOperator?.npub == op.npub {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            if case .loadingTools = vm.state {
                HStack {
                    ProgressView()
                    Text("Loading tools…").foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var toolSection: some View {
        let grouped = Dictionary(grouping: vm.availableTools, by: \.category)
        Section("Tool") {
            ForEach(grouped.keys.sorted(), id: \.self) { category in
                if let tools = grouped[category] {
                    ForEach(tools) { tool in
                        Button {
                            vm.selectedTool = tool
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tool.toolName)
                                        .font(.subheadline.monospaced())
                                    Text(tool.intent)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Text("\(tool.priceSats) sats")
                                    .font(.caption.bold())
                                    .foregroundStyle(tool.priceSats == 0 ? .green : .orange)
                                if vm.selectedTool?.toolName == tool.toolName {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var identitySection: some View {
        let identities = vm.availableIdentities(operators: operators, patrons: patrons)
        Section("Call as Npub") {
            if identities.isEmpty {
                Text("No identities with nsec keys for this tool role")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(identities, id: \.npub) { identity in
                    Button {
                        vm.selectedPatronNpub = identity.npub
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                HStack(spacing: 4) {
                                    Image(systemName: identity.role == .operator ? "gearshape.fill" : "person.fill")
                                        .font(.caption)
                                        .foregroundStyle(identity.role == .operator ? .blue : .teal)
                                    Text(identity.displayName).font(.subheadline)
                                }
                                Text(String(identity.npub.prefix(16)) + "…")
                                    .font(.caption).monospaced()
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if vm.selectedPatronNpub == identity.npub {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        Section {
            if case .ready(let estimate) = vm.state {
                Button {
                    Task { await vm.executeCall() }
                } label: {
                    Label("Execute", systemImage: "bolt.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!estimate.canAfford && estimate.requiredRole != .operator)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Tool Cost:")
                        Spacer()
                        Text("\(estimate.estimatedCostSats) sats")
                            .bold()
                            .foregroundStyle(estimate.estimatedCostSats == 0 ? .green : .primary)
                    }

                    if estimate.requiredRole != .operator {
                        HStack {
                            Text("Balance:")
                            Spacer()
                            Text("\(estimate.currentBalanceSats) sats")
                                .bold()
                        }

                        HStack {
                            Text("Affordable:")
                            Spacer()
                            Image(systemName: estimate.canAfford ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(estimate.canAfford ? .green : .red)
                        }
                    }
                }
                .font(.caption)
            } else {
                Button {
                    Task { await vm.checkAffordability() }
                } label: {
                    Label("Check Affordability", systemImage: "creditcard")
                }
                .disabled(vm.selectedTool == nil || vm.selectedPatronNpub == nil)

                if case .checkingBalance = vm.state {
                    HStack {
                        ProgressView()
                        Text("Checking balance…").foregroundStyle(.secondary)
                    }
                }

                if case .executing = vm.state {
                    HStack {
                        ProgressView()
                        Text("Executing…").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        switch vm.state {
        case .result(let text):
            Section("Result") {
                ScrollView {
                    Text(prettyPrintJSON(text))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
            }
        case .error(let message):
            Section("Error") {
                Text(message)
                    .foregroundStyle(.red)
                    .font(.subheadline)
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Helpers

    /// Pretty-print JSON response. Does NOT follow embedded URLs.
    private func prettyPrintJSON(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let result = String(data: pretty, encoding: .utf8) else {
            return text
        }
        return result
    }
}
