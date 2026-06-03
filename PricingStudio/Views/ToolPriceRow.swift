import SwiftUI

struct ToolPriceRow: View {
    let tool: ToolPrice
    let viewModel: PricingViewModel?
    var target: (any PricingTarget)?
    /// When non-empty, edits apply to every selected tool (batch mode).
    var selectedToolIds: Set<String> = []
    var allTools: [ToolPrice] = []
    /// Forwarded to the chain editor so the coupon-picker ParamType
    /// can show the operator's coupons.
    var couponViewModel: CouponViewModel? = nil
    @State private var showingInfo = false
    @State private var showingEditor = false
    @State private var showingTestCall = false
    @State private var showingChain = false

    init(
        tool: ToolPrice,
        viewModel: PricingViewModel? = nil,
        target: (any PricingTarget)? = nil,
        selectedToolIds: Set<String> = [],
        allTools: [ToolPrice] = [],
        couponViewModel: CouponViewModel? = nil,
    ) {
        self.tool = tool
        self.viewModel = viewModel
        self.target = target
        self.selectedToolIds = selectedToolIds
        self.allTools = allTools
        self.couponViewModel = couponViewModel
    }

    /// Tool names for batch apply — all selected tools except this one (this one is handled directly).
    private var batchToolNames: [String] {
        guard !selectedToolIds.isEmpty, selectedToolIds.contains(tool.toolId) else { return [] }
        return allTools
            .filter { selectedToolIds.contains($0.toolId) && $0.toolId != tool.toolId }
            .map(\.toolName)
    }

    private var effectiveTool: ToolPrice {
        viewModel?.editedTool(for: tool.toolId) ?? tool
    }

    private var isEdited: Bool {
        viewModel?.editedTool(for: tool.toolId) != nil
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(tool.toolName)
                .font(.subheadline.monospaced())
                .contextMenu {
                    if target?.mcpEndpointURL != nil {
                        Button {
                            showingTestCall = true
                        } label: {
                            Label("Execute Request as Identity…", systemImage: "play.circle")
                        }
                    }
                }

            if !tool.intent.isEmpty {
                Button {
                    showingInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingInfo) {
                    Text(tool.intent)
                        .font(.callout)
                        .padding()
                        .frame(idealWidth: 260)
                        .presentationCompactAdaptation(.popover)
                }
            }

            Spacer()

            chainBadge

            priceBadge
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $showingTestCall) {
            TestCallView(preselectedTarget: target, preselectedTool: tool)
        }
        .sheet(isPresented: $showingChain) {
            chainSheet
        }
    }

    @ViewBuilder
    private var chainBadge: some View {
        let count = effectiveTool.chain.count
        Button {
            if viewModel != nil { showingChain = true }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: count > 0 ? "link.circle.fill" : "link.circle")
                    .font(.caption)
                Text(count == 0 ? "Chain" : "\(count)")
                    .font(.caption2.monospaced())
            }
            .foregroundStyle(count > 0 ? .purple : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.4), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chainBadge_\(tool.toolName)")
    }

    /// Tool ids that should ALSO receive any chain edits made in this row's
    /// sheet — every other multi-selected tool (this row is the primary).
    /// Mirrors the price-edit batch-apply pattern: edit one, save many.
    private var chainBatchToolIds: [String] {
        guard !selectedToolIds.isEmpty, selectedToolIds.contains(tool.toolId) else { return [] }
        return selectedToolIds.filter { $0 != tool.toolId }
    }

    @ViewBuilder
    private var chainSheet: some View {
        if let vm = viewModel {
            // Fan-out targets: this row's tool + every other selected
            // tool.  Every mutation in the chain editor is mirrored to
            // each, so dragging / adding / removing one step writes
            // through to the whole batch.
            let batchIds = chainBatchToolIds
            let allIds: [String] = [tool.toolId] + batchIds
            NavigationStack {
                ScrollView {
                    ToolChainView(
                        tool: effectiveTool,
                        isEditing: true,
                        chain: Binding(
                            get: { vm.chain(for: tool.toolId) },
                            set: { newChain in
                                for tid in allIds {
                                    vm.beginChainEditing(toolId: tid)
                                    if var draft = vm.localEdits[tid] {
                                        draft.chain = newChain
                                        vm.localEdits[tid] = draft
                                    }
                                }
                            }
                        ),
                        warnings: vm.chainWarnings[tool.toolId] ?? [],
                        batchToolCount: batchIds.count,
                        couponViewModel: couponViewModel,
                    )
                    .padding()
                }
                .navigationTitle(batchIds.isEmpty
                    ? "Constraints"
                    : "Constraints · \(allIds.count) tools")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingChain = false }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var priceBadge: some View {
        let display = effectiveTool

        Button {
            if viewModel != nil {
                showingEditor.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                if isEdited {
                    Image(systemName: "pencil")
                        .font(.caption2)
                }
                priceBadgeLabel(for: display)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingEditor) {
            if let viewModel {
                ToolPriceEditor(
                    tool: effectiveTool,
                    viewModel: viewModel,
                    isPresented: $showingEditor,
                    batchToolNames: batchToolNames
                )
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    private func priceBadgeLabel(for tool: ToolPrice) -> some View {
        let badgeColor: Color = isEdited ? .blue : !tool.priced ? .gray : (tool.priceSats == 0 ? .green : .orange)
        let base: String = {
            if !tool.priced { return "TBD" }
            switch tool.priceType {
            case .flat:
                if tool.priceSats == 0 { return "FREE" }
                return "\(tool.priceSats) sat\(tool.priceSats == 1 ? "" : "s")"
            case .percent:
                if let param = tool.priceFormula, !param.isEmpty, !param.hasSuffix("%") {
                    return "\(tool.priceSats)% of \(param)"
                }
                return "\(tool.priceSats)%"
            case .formula:
                return tool.priceFormula ?? "formula"
            }
        }()
        let suffix: String = (tool.multipliers?.isEmpty == false && tool.priced) ? " × f(v)" : ""
        return Text(base + suffix)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(badgeColor.opacity(0.15), in: Capsule())
            .foregroundStyle(badgeColor)
    }
}

// MARK: - Multiplier editing state

/// A single (value, multiplier) row inside one parameter's lookup table.
private struct MultiplierEntry: Identifiable {
    let id = UUID()
    var key: String
    var multiplier: String   // text-backed so mid-typing doesn't reject
}

/// One named parameter (e.g. "difficulty") with its enum-keyed lookup table.
private struct MultiplierParam: Identifiable {
    let id = UUID()
    var name: String
    var entries: [MultiplierEntry]
}

private extension Array where Element == MultiplierParam {
    /// Convert the editor's ordered list back to the wire dict shape, dropping
    /// rows with empty names/keys or unparseable multipliers.
    func toWireDict() -> [String: [String: Double]] {
        var out: [String: [String: Double]] = [:]
        for p in self {
            let pname = p.name.trimmingCharacters(in: .whitespaces)
            guard !pname.isEmpty else { continue }
            var lookup: [String: Double] = [:]
            for e in p.entries {
                let k = e.key.trimmingCharacters(in: .whitespaces)
                guard !k.isEmpty, let v = Double(e.multiplier.trimmingCharacters(in: .whitespaces)) else { continue }
                lookup[k] = v
            }
            if !lookup.isEmpty { out[pname] = lookup }
        }
        return out
    }

    static func fromWireDict(_ dict: [String: [String: Double]]?) -> [MultiplierParam] {
        guard let dict, !dict.isEmpty else { return [] }
        // Stable ordering: alphabetical by param name, alphabetical by key within.
        return dict.keys.sorted().map { pname in
            let lookup = dict[pname] ?? [:]
            let entries = lookup.keys.sorted().map { k in
                MultiplierEntry(key: k, multiplier: trimNumber(lookup[k] ?? 1.0))
            }
            return MultiplierParam(name: pname, entries: entries)
        }
    }
}

/// Render `1.0` as `"1"` but `1.5` as `"1.5"` — keeps simple integer multipliers tidy.
private func trimNumber(_ d: Double) -> String {
    d.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(d))" : "\(d)"
}

// MARK: - Tool Price Editor Popover

private struct ToolPriceEditor: View {
    let tool: ToolPrice
    let viewModel: PricingViewModel
    @Binding var isPresented: Bool
    /// Additional tool names to apply the same edit to (batch mode).
    var batchToolNames: [String] = []

    @State private var editType: PriceType
    @State private var editSats: String
    @State private var editPercent: String
    @State private var editRateParam: String
    @State private var editFormula: String
    @State private var editMinCost: String
    @State private var editMaxCost: String
    @State private var editCategory: String
    @State private var editMultipliers: [MultiplierParam]

    private static let categoryOptions: [(value: String, label: String)] = [
        ("free", "Free"),
        ("auth", "Auth & Balance"),
        ("read", "Read (1 sat)"),
        ("write", "Write (5 sats)"),
        ("heavy", "Heavy (10 sats)"),
        ("restricted", "Restricted (Operator Only)")
    ]

    init(tool: ToolPrice, viewModel: PricingViewModel, isPresented: Binding<Bool>, batchToolNames: [String] = []) {
        self.tool = tool
        self.viewModel = viewModel
        self._isPresented = isPresented
        self.batchToolNames = batchToolNames
        self._editType = State(initialValue: tool.priceType)
        self._editSats = State(initialValue: "\(tool.priceSats)")
        self._editPercent = State(initialValue: "\(tool.priceSats)")

        // For percent type, price_formula holds the rate_param (tool argument name).
        // Legacy data may store "5%" — strip the suffix for the rate param field.
        let rateParam: String
        if tool.priceType == .percent, let formula = tool.priceFormula {
            rateParam = formula.hasSuffix("%") ? "" : formula
        } else {
            rateParam = ""
        }
        self._editRateParam = State(initialValue: rateParam)

        self._editFormula = State(initialValue: tool.priceFormula ?? "")
        self._editMinCost = State(initialValue: tool.minCost == 0 ? "" : "\(tool.minCost)")
        self._editMaxCost = State(initialValue: tool.maxCost.map { "\($0)" } ?? "")
        self._editCategory = State(initialValue: tool.category)
        self._editMultipliers = State(initialValue: [MultiplierParam].fromWireDict(tool.multipliers))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if batchToolNames.isEmpty {
                Text(tool.toolName)
                    .font(.headline.monospaced())
                    .lineLimit(1)
            } else {
                Text("\(tool.toolName) + \(batchToolNames.count) more")
                    .font(.headline.monospaced())
                    .lineLimit(1)
            }

            Picker("Category", selection: $editCategory) {
                ForEach(Self.categoryOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }

            Picker("Type", selection: $editType) {
                Text("Flat").tag(PriceType.flat)
                Text("Ad Valorem").tag(PriceType.percent)
                Text("Formula").tag(PriceType.formula)
            }
            .pickerStyle(.segmented)

            switch editType {
            case .flat:
                HStack {
                    TextField("Sats", text: $editSats)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("sats")
                        .foregroundStyle(.secondary)
                }
            case .percent:
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Rate", text: $editPercent)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Text("% of")
                            .foregroundStyle(.secondary)
                        TextField("param name", text: $editRateParam)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .monospaced()
                    }
                    Text("Ad valorem: percentage of a tool call argument (e.g. amount_sats)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            case .formula:
                TextField("Formula", text: $editFormula)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 8) {
                HStack {
                    TextField("Min (sats)", text: $editMinCost)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("min")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                HStack {
                    TextField("Max (sats)", text: $editMaxCost)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("max")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }

            multipliersSection

            HStack {
                Button("Apply") {
                    let sats: Int
                    let formula: String?
                    switch editType {
                    case .flat:
                        sats = Int(editSats) ?? 0
                        formula = nil
                    case .percent:
                        // price_sats = the rate percentage, price_formula = the tool argument name
                        sats = Int(editPercent) ?? 0
                        let param = editRateParam.trimmingCharacters(in: .whitespaces)
                        formula = param.isEmpty ? nil : param
                    case .formula:
                        sats = 0
                        formula = editFormula
                    }
                    let minCost = Int(editMinCost) ?? 0
                    let maxCost = editMaxCost.isEmpty ? nil : Int(editMaxCost)
                    // Empty dict = explicit removal; nil would mean "no change".
                    let mults: [String: [String: Double]] = editMultipliers.toWireDict()
                    let names = [tool.toolName] + batchToolNames
                    for name in names {
                        viewModel.applyEdit(
                            toolName: name,
                            priceSats: sats,
                            priceType: editType,
                            priceFormula: formula,
                            minCost: minCost,
                            maxCost: maxCost,
                            category: editCategory,
                            multipliers: mults
                        )
                    }
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Reset") {
                    viewModel.resetEdit(toolId: tool.toolId)
                    isPresented = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if tool.priced {
                    Button("TBD") {
                        viewModel.markTBD(toolId: tool.toolId)
                        isPresented = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundStyle(.gray)
                }
            }
        }
        .padding()
        .frame(width: 380)
    }

    // MARK: - Multipliers section

    @ViewBuilder
    private var multipliersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Multipliers")
                    .font(.subheadline.weight(.semibold))
                Text("price × ∏ f(v)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    editMultipliers.append(MultiplierParam(name: "", entries: [MultiplierEntry(key: "", multiplier: "1")]))
                } label: {
                    Label("Add v", systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }

            if editMultipliers.isEmpty {
                Text("No categorical multipliers. Add a parameter (e.g. `difficulty`) to scale price by enum values.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach($editMultipliers) { $param in
                    multiplierParamCard(param: $param)
                }
            }
        }
    }

    @ViewBuilder
    private func multiplierParamCard(param: Binding<MultiplierParam>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("parameter name (v)", text: param.name)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .monospaced()
                    .font(.caption)
                Button(role: .destructive) {
                    editMultipliers.removeAll { $0.id == param.wrappedValue.id }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            ForEach(param.entries) { $entry in
                HStack(spacing: 4) {
                    TextField("value", text: $entry.key)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .monospaced()
                        .font(.caption)
                    Text("→")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("×", text: $entry.multiplier)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .font(.caption)
                    Button(role: .destructive) {
                        param.wrappedValue.entries.removeAll { $0.id == entry.id }
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button {
                param.wrappedValue.entries.append(MultiplierEntry(key: "", multiplier: "1"))
            } label: {
                Label("Add entry", systemImage: "plus")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }
}
