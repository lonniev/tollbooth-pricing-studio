import SwiftUI

struct ReconciliationSheet: View {
    @Bindable var viewModel: ReconciliationViewModel
    let storedModel: PricingModelResponse
    var onApply: (([ToolPrice], MCPService.ToolMismatch) -> Void)?
    /// Persist the staged edits directly to the operator's pricing model
    /// (Neon). Invoked by Done so leaving Reconcile saves without a second
    /// Apply on the Operator screen.
    var onDone: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var applied = false

    var body: some View {
        NavigationStack {
            Group {
                if applied {
                    appliedPhase
                } else if viewModel.isDetecting {
                    detectingPhase
                } else if let error = viewModel.error {
                    errorPhase(error)
                } else if let suggested = viewModel.suggestedTools, let mismatch = viewModel.mismatch {
                    reviewPhase(suggested: suggested, mismatch: mismatch)
                } else if let mismatch = viewModel.mismatch, mismatch.hasMismatch {
                    diagnosticPhase(mismatch: mismatch)
                } else if let msg = viewModel.noMismatchMessage {
                    successPhase(msg)
                } else {
                    ProgressView("Preparing...")
                }
            }
            .navigationTitle("Reconcile Tools")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { finish() }
                }
            }
        }
    }

    // MARK: - Finish (Done)

    /// The reconciliation to stage when the user taps Done without having
    /// tapped Apply first. `nil` once Apply has already staged (``applied``),
    /// or when no reconciled result is on screen to stage.
    static func pendingReconciliation(
        applied: Bool,
        suggested: [ToolPrice]?,
        mismatch: MCPService.ToolMismatch?
    ) -> (suggested: [ToolPrice], mismatch: MCPService.ToolMismatch)? {
        guard !applied, let suggested, let mismatch else { return nil }
        return (suggested, mismatch)
    }

    /// Stage any pending reconciliation, persist it to the operator's pricing
    /// model, and dismiss. Both the toolbar Done and the applied-phase Done
    /// invoke this so leaving Reconcile saves directly to Neon — no separate
    /// Apply on the Operator screen required.
    private func finish() {
        if let pending = Self.pendingReconciliation(
            applied: applied,
            suggested: viewModel.suggestedTools,
            mismatch: viewModel.mismatch
        ) {
            onApply?(pending.suggested, pending.mismatch)
        }
        onDone?()
        dismiss()
    }

    // MARK: - Detecting

    private var detectingPhase: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Detecting tool mismatch...")
                .font(.headline)
            Text("Connecting to live MCP endpoint and comparing against stored pricing model.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    // MARK: - Diagnostic (mismatch found, offer to reconcile)

    @ViewBuilder
    private func diagnosticPhase(mismatch: MCPService.ToolMismatch) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !mismatch.newIdentities.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("\(mismatch.newIdentities.count) New Tools", systemImage: "plus.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.green)

                        ForEach(mismatch.newIdentities, id: \.toolId) { canon in
                            HStack {
                                Text(canon.mcpName)
                                    .font(.caption.monospaced())
                                Spacer()
                                Text("will be added at 0 sats (\(canon.category))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding()
                    .background(.green.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                }

                if !mismatch.staleTools.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("\(mismatch.staleTools.count) Stale Tools", systemImage: "minus.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.red)

                        ForEach(mismatch.staleTools) { tool in
                            HStack {
                                Text(tool.toolName)
                                    .font(.caption.monospaced())
                                Spacer()
                                Text("will be removed")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding()
                    .background(.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                }

                Text("\(mismatch.matchedTools.count) tools match and will be preserved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    viewModel.reconcile(storedModel: storedModel)
                } label: {
                    Label("Reconcile", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
        }
    }

    // MARK: - Review (reconciled result, offer to apply)

    @ViewBuilder
    private func reviewPhase(suggested: [ToolPrice], mismatch: MCPService.ToolMismatch) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Button {
                    onApply?(suggested, mismatch)
                    applied = true
                } label: {
                    Label("Apply", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                let newToolNames = Set(mismatch.newIdentities.map(\.mcpName))
                let grouped = Dictionary(grouping: suggested) { $0.category }
                let order = ["free", "auth", "read", "write", "heavy", "restricted"]

                ForEach(order, id: \.self) { category in
                    if let tools = grouped[category] {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(categoryDisplayName(category))
                                .font(.headline)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)

                            ForEach(tools) { tool in
                                HStack {
                                    if newToolNames.contains(tool.toolName) {
                                        Text("NEW")
                                            .font(.caption2.bold())
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(.green, in: Capsule())
                                    }
                                    Text(tool.toolName)
                                        .font(.caption.monospaced())
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(tool.priceSats) sats")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.blue)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }

                if !mismatch.staleTools.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Removed")
                            .font(.headline)
                            .foregroundStyle(.red)
                            .textCase(.uppercase)

                        ForEach(mismatch.staleTools) { tool in
                            HStack {
                                Text(tool.toolName)
                                    .font(.caption.monospaced())
                                    .strikethrough()
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(tool.priceSats) sats")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Button("Dismiss") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding()
        }
    }

    // MARK: - Applied

    private var appliedPhase: some View {
        ContentUnavailableView {
            Label("Pricing Model Updated", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        } description: {
            Text("Pricing model is now aligned with the latest code and conventions.")
        } actions: {
            Button("Done") { finish() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - All Good

    private func successPhase(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Tools in Sync", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } description: {
            Text(message)
        } actions: {
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Error

    private func errorPhase(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Reconciliation Issue", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
                .font(.caption)
        } actions: {
            Button("Dismiss") { dismiss() }
                .buttonStyle(.bordered)
        }
    }

    // MARK: - Helpers

    private func categoryDisplayName(_ category: String) -> String {
        switch category {
        case "free": return "Free"
        case "auth": return "Authentication"
        case "read": return "Read"
        case "write": return "Write"
        case "heavy": return "Heavy"
        case "restricted": return "Restricted"
        default: return category
        }
    }
}
