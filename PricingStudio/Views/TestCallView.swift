import SwiftUI
import SwiftData

/// Dry-run tool call simulation — pick operator, tool, identity, check affordability, execute.
struct TestCallView: View {
    @State private var vm = TestCallViewModel()
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Operator.addedAt) private var operators: [Operator]
    @Query(sort: \Patron.addedAt) private var patrons: [Patron]
    @Query(sort: \Authority.addedAt) private var authorities: [Authority]

    /// Pre-selected operator (when launched from operator detail or tool row).
    var preselectedOperator: Operator?
    /// Pre-selected target (PricingTarget — Operator or Authority).
    var preselectedTarget: (any PricingTarget)?
    /// Pre-selected tool (when launched from a specific tool row long-press).
    var preselectedTool: ToolPrice?

    /// When both operator/target and tool are pre-selected, lead with identity + execute.
    private var isDirectMode: Bool { (preselectedOperator != nil || preselectedTarget != nil) && preselectedTool != nil }

    var body: some View {
        NavigationStack {
            Form {
                if isDirectMode {
                    // Focused mode: identity → params → execute → result
                    // Operator and tool already chosen — keep it tight
                    toolSummarySection
                    identitySection
                    if !vm.toolParams.isEmpty { parametersSection }
                    resultSection
                    actionSection
                } else {
                    // Browse mode: operator → tool → identity → params → execute
                    operatorSection
                    if !vm.availableTools.isEmpty { toolSection }
                    if vm.selectedTool != nil { identitySection }
                    if !vm.toolParams.isEmpty { parametersSection }
                    resultSection
                    actionSection
                }
            }
            .navigationTitle(isDirectMode ? (vm.selectedTool?.toolName ?? "Test Call") : "Test Call")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                guard vm.selectedOperator == nil else { return }
                // Resolve pre-selected operator from either direct operator or PricingTarget
                let op: Operator? = preselectedOperator
                    ?? (preselectedTarget as? Operator)
                    ?? resolveAuthorityAsOperator()
                if let op {
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
        let identities = vm.availableIdentities(operators: operators, patrons: patrons, authorities: authorities)
        Section("Call as Identity") {
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
    private var parametersSection: some View {
        Section("Parameters") {
            ForEach(vm.toolParams) { param in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(param.name)
                            .font(.caption.bold().monospaced())
                        if param.required {
                            Text("required")
                                .font(.system(size: 9))
                                .foregroundStyle(.red)
                        }
                        Spacer()
                        Text(param.type)
                            .font(.system(size: 9).monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    if !param.description.isEmpty {
                        Text(param.description)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if param.name == "npub" {
                        // npub is auto-filled from identity selection
                        Text(vm.paramValues["npub", default: "select identity above"])
                            .font(.caption.monospaced())
                            .foregroundStyle(.green)
                    } else if param.type == "boolean" {
                        Toggle("", isOn: Binding(
                            get: { vm.paramValues[param.name, default: "false"] == "true" },
                            set: { vm.paramValues[param.name] = $0 ? "true" : "false" }
                        ))
                    } else {
                        TextField(
                            param.defaultValue.isEmpty ? param.name : param.defaultValue,
                            text: Binding(
                                get: { vm.paramValues[param.name, default: ""] },
                                set: { vm.paramValues[param.name] = $0 }
                            )
                        )
                        .font(.caption.monospaced())
                        .textFieldStyle(.roundedBorder)
                    }
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
                    Text("🚀 Execute")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!estimate.canAfford && estimate.requiredRole != .operator)

                VStack(alignment: .leading, spacing: 6) {
                    if estimate.isFree {
                        HStack {
                            Text("Effective Cost:")
                            Spacer()
                            Text("FREE")
                                .bold()
                                .foregroundStyle(.green)
                        }
                        if estimate.baseCostSats > 0 {
                            HStack {
                                Text("Base Price:")
                                Spacer()
                                Text("\(estimate.baseCostSats) sats")
                                    .strikethrough()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        HStack {
                            Text("Effective Cost:")
                            Spacer()
                            Text("\(estimate.estimatedCostSats) sats")
                                .bold()
                        }
                        if estimate.constraintsActive && estimate.baseCostSats != estimate.estimatedCostSats {
                            HStack {
                                Text("Base Price:")
                                Spacer()
                                Text("\(estimate.baseCostSats) sats")
                                    .strikethrough()
                                    .foregroundStyle(.secondary)
                            }
                        }
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

                if case .oauthPolling(let remaining) = vm.state {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            ProgressView()
                            Text("Waiting for browser authorization…")
                                .foregroundStyle(.secondary)
                        }
                        Text("\(remaining)s remaining")
                            .font(.caption.monospacedDigit().bold())
                            .foregroundStyle(remaining <= 10 ? .red : .orange)
                        Text("Complete the sign-in in your browser. The app will detect it automatically.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
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
                    if let json = tryPrettyJSON(text) {
                        Text(json)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        MarkdownContentView(text: text)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
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

    /// Resolve a pre-selected Authority target as an Operator (for the VM).
    /// Looks for a matching Operator by npub, or creates a synthetic match
    /// from the Authority's endpoint info.
    private func resolveAuthorityAsOperator() -> Operator? {
        guard let target = preselectedTarget else { return nil }
        // Check if there's already an Operator with this npub
        if let match = operators.first(where: { $0.npub == target.npub }) {
            return match
        }
        // For authorities, also check authorities list — Authority is a PricingTarget
        // with mcpEndpointURL, so we can construct a temporary operator-like object
        if let auth = target as? Authority,
           let _ = auth.mcpEndpointURL {
            // Find or synthesize — authorities ARE in the operators query if added as operators too
            return operators.first(where: { $0.mcpEndpointURL == auth.mcpEndpointURL })
        }
        return nil
    }

    /// Try to pretty-print as JSON. Returns nil if not valid JSON.
    private func tryPrettyJSON(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let result = String(data: pretty, encoding: .utf8) else {
            return nil
        }
        return result
    }
}
