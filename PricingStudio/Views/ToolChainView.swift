import SwiftUI

/// Per-tool constraint chain editor.  Opened by drilling into a
/// ``ToolPriceRow``.  The chain belongs to one tool; tool scope is
/// implicit, so the affordances here are add / clone / remove /
/// reorder, plus an optional patron audience filter per step.
struct ToolChainView: View {
    let tool: ToolPrice
    let isEditing: Bool
    @Binding var chain: [PipelineStep]
    /// Validation warnings for this tool's chain, indexed by step
    /// position (1-based).  Empty when the chain is clean.
    var warnings: [String] = []
    /// Number of *additional* tools that will receive these edits via
    /// the multi-select batch-apply.  0 = edits stay on `tool` only.
    var batchToolCount: Int = 0
    /// Operator-side coupon catalog.  Forwarded to constraint sheets
    /// so the coupon-picker ParamType can render a dropdown.
    var couponViewModel: CouponViewModel? = nil

    @State private var showingAddSheet = false
    @State private var editingStep: PipelineStep?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if chain.isEmpty && !isEditing {
                Text("No constraints on this tool")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                stepList
            }

            if isEditing {
                Button {
                    showingAddSheet = true
                } label: {
                    Label("Add Constraint", systemImage: "plus.circle.fill")
                        .font(.subheadline)
                }
                .accessibilityIdentifier("addConstraintButton")
                .padding(.top, 12)
            }

            if !warnings.isEmpty {
                warningsBlock
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddConstraintSheet(
                onAdd: { type, params, patronNpubs in
                    withAnimation {
                        chain.append(PipelineStep.create(type: type, params: params, patronNpubs: patronNpubs))
                    }
                },
                couponViewModel: couponViewModel,
            )
        }
        .sheet(item: $editingStep) { step in
            if let spec = ConstraintCatalog.spec(for: step.displayType) {
                ConstraintParamEditor(
                    spec: spec,
                    existingParams: step.params,
                    onSave: { newParams in
                        if let idx = chain.firstIndex(where: { $0.id == step.id }) {
                            chain[idx] = PipelineStep(
                                id: step.id, type: step.type, params: newParams,
                                patronNpubs: step.patronNpubs
                            )
                        }
                    },
                    couponViewModel: couponViewModel,
                )
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Constraint Chain")
                .font(.title3.bold())
            Text(tool.toolName)
                .font(.headline)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Label("\(tool.priceSats) sat\(tool.priceSats == 1 ? "" : "s") base", systemImage: "tag")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if !tool.intent.isEmpty {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(tool.intent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if batchToolCount > 0 {
                Label(
                    "Edits cascade to \(batchToolCount) other selected tool\(batchToolCount == 1 ? "" : "s")",
                    systemImage: "rectangle.stack.fill.badge.person.crop"
                )
                .font(.caption)
                .foregroundStyle(.blue)
                .padding(.top, 4)
            }
        }
        .padding(.bottom, 16)
    }

    private var stepList: some View {
        let items = Array(chain)
        return ForEach(items.indices, id: \.self) { index in
            let step = items[index]
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 0) {
                    Circle()
                        .fill(.tint)
                        .frame(width: 12, height: 12)
                    if index < items.count - 1 {
                        Rectangle()
                            .fill(.tint.opacity(0.3))
                            .frame(width: 2)
                            .frame(minHeight: 60)
                    }
                }
                .frame(width: 12)

                HStack {
                    PipelineStepCard(step: step)
                        .padding(.bottom, index < items.count - 1 ? 8 : 0)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if isEditing { editingStep = step }
                        }

                    if isEditing {
                        VStack(spacing: 8) {
                            Button {
                                withAnimation {
                                    let clone = PipelineStep.create(
                                        type: step.type, params: step.params,
                                        patronNpubs: step.patronNpubs
                                    )
                                    if let idx = chain.firstIndex(where: { $0.id == step.id }) {
                                        chain.insert(clone, at: idx + 1)
                                    }
                                }
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .foregroundStyle(.blue)
                                    .imageScale(.medium)
                            }
                            .buttonStyle(.plain)
                            .help("Clone constraint")

                            Button(role: .destructive) {
                                withAnimation {
                                    chain.removeAll { $0.id == step.id }
                                }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                                    .imageScale(.medium)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .accessibilityIdentifier("chainStepRow_\(index)")
            }
        }
        .onMove { source, destination in
            if isEditing {
                chain.move(fromOffsets: source, toOffset: destination)
            }
        }
    }

    private var warningsBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(warnings.indices, id: \.self) { i in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .imageScale(.small)
                    Text(warnings[i])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 12)
    }
}
