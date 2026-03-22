import SwiftUI
import SwiftData

/// Dry-run tool call simulation — pick operator, tool, identity, check affordability, execute.
struct TestCallView: View {
    @State private var vm = TestCallViewModel()
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Operator.addedAt) private var operators: [Operator]
    @Query(sort: \Patron.addedAt) private var patrons: [Patron]

    /// Pre-selected operator (when launched from operator detail).
    var preselectedOperator: Operator?

    var body: some View {
        NavigationStack {
            Form {
                operatorSection
                if !vm.availableTools.isEmpty { toolSection }
                if vm.selectedTool != nil { identitySection }
                actionSection
                resultSection
            }
            .navigationTitle("Test Call")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if let op = preselectedOperator, vm.selectedOperator == nil {
                    vm.selectedOperator = op
                    Task { await vm.loadTools() }
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
        Section("Identity") {
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
        Section("Action") {
            if case .ready(let estimate) = vm.state {
                VStack(alignment: .leading, spacing: 8) {
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
                            Text("Can Afford:")
                            Spacer()
                            Image(systemName: estimate.canAfford ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(estimate.canAfford ? .green : .red)
                            Text(estimate.canAfford ? "Yes" : "No")
                                .foregroundStyle(estimate.canAfford ? .green : .red)
                        }
                    }
                }

                Button {
                    Task { await vm.executeCall() }
                } label: {
                    Label("Execute Call", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!estimate.canAfford && estimate.requiredRole != .operator)
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
                    Text(text)
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
}
