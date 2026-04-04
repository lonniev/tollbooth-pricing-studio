import SwiftUI

struct ToolPriceRow: View {
    let tool: ToolPrice
    let viewModel: PricingViewModel?
    var target: (any PricingTarget)?
    @State private var showingInfo = false
    @State private var showingEditor = false
    @State private var showingTestCall = false

    init(tool: ToolPrice, viewModel: PricingViewModel? = nil, target: (any PricingTarget)? = nil) {
        self.tool = tool
        self.viewModel = viewModel
        self.target = target
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

            priceBadge
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $showingTestCall) {
            TestCallView(preselectedTarget: target, preselectedTool: tool)
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
                    isPresented: $showingEditor
                )
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    private func priceBadgeLabel(for tool: ToolPrice) -> some View {
        let badgeColor: Color = isEdited ? .blue : (tool.priceSats == 0 ? .green : .orange)
        let label: String = {
            switch tool.priceType {
            case .flat:
                return tool.priceSats == 0 ? "FREE" : "\(tool.priceSats) sat\(tool.priceSats == 1 ? "" : "s")"
            case .percent:
                if let param = tool.priceFormula, !param.isEmpty, !param.hasSuffix("%") {
                    return "\(tool.priceSats)% of \(param)"
                }
                return "\(tool.priceSats)%"
            case .formula:
                return tool.priceFormula ?? "formula"
            }
        }()
        return Text(label)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(badgeColor.opacity(0.15), in: Capsule())
            .foregroundStyle(badgeColor)
    }
}

// MARK: - Tool Price Editor Popover

private struct ToolPriceEditor: View {
    let tool: ToolPrice
    let viewModel: PricingViewModel
    @Binding var isPresented: Bool

    @State private var editType: PriceType
    @State private var editSats: String
    @State private var editPercent: String
    @State private var editRateParam: String
    @State private var editFormula: String
    @State private var editMinCost: String
    @State private var editMaxCost: String
    @State private var editCategory: String

    private static let categoryOptions: [(value: String, label: String)] = [
        ("free", "Free"),
        ("auth", "Auth & Balance"),
        ("read", "Read (1 sat)"),
        ("write", "Write (5 sats)"),
        ("heavy", "Heavy (10 sats)"),
        ("restricted", "Restricted (Operator Only)")
    ]

    init(tool: ToolPrice, viewModel: PricingViewModel, isPresented: Binding<Bool>) {
        self.tool = tool
        self.viewModel = viewModel
        self._isPresented = isPresented
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
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tool.toolName)
                .font(.headline.monospaced())
                .lineLimit(1)

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
                    viewModel.applyEdit(
                        toolName: tool.toolName,
                        priceSats: sats,
                        priceType: editType,
                        priceFormula: formula,
                        minCost: minCost,
                        maxCost: maxCost,
                        category: editCategory
                    )
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
            }
        }
        .padding()
        .frame(width: 320)
    }
}
