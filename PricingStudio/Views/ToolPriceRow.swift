import SwiftUI

struct ToolPriceRow: View {
    let tool: ToolPrice
    let viewModel: PricingViewModel?
    @State private var showingInfo = false
    @State private var showingEditor = false

    init(tool: ToolPrice, viewModel: PricingViewModel? = nil) {
        self.tool = tool
        self.viewModel = viewModel
    }

    private var effectiveTool: ToolPrice {
        viewModel?.editedTool(for: tool.toolName) ?? tool
    }

    private var isEdited: Bool {
        viewModel?.editedTool(for: tool.toolName) != nil
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(tool.toolName)
                .font(.subheadline.monospaced())

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
                return tool.priceFormula ?? "\(tool.priceSats)%"
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
    @State private var editFormula: String

    init(tool: ToolPrice, viewModel: PricingViewModel, isPresented: Binding<Bool>) {
        self.tool = tool
        self.viewModel = viewModel
        self._isPresented = isPresented
        self._editType = State(initialValue: tool.priceType)
        self._editSats = State(initialValue: "\(tool.priceSats)")
        self._editPercent = State(initialValue: tool.priceFormula ?? "\(tool.priceSats)")
        self._editFormula = State(initialValue: tool.priceFormula ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tool.toolName)
                .font(.headline.monospaced())
                .lineLimit(1)

            Picker("Type", selection: $editType) {
                ForEach(PriceType.allCases, id: \.self) { type in
                    Text(type.rawValue.capitalized).tag(type)
                }
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
                HStack {
                    TextField("Percent", text: $editPercent)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("%")
                        .foregroundStyle(.secondary)
                }
            case .formula:
                TextField("Formula", text: $editFormula)
                    .textFieldStyle(.roundedBorder)
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
                        sats = Int(editPercent) ?? 0
                        formula = editPercent + "%"
                    case .formula:
                        sats = 0
                        formula = editFormula
                    }
                    viewModel.applyEdit(
                        toolName: tool.toolName,
                        priceSats: sats,
                        priceType: editType,
                        priceFormula: formula
                    )
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Reset") {
                    viewModel.resetEdit(toolName: tool.toolName)
                    isPresented = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding()
        .frame(width: 260)
    }
}
