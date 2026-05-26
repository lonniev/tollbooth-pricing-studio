import SwiftUI

struct ReconciliationSheet: View {
    @Bindable var viewModel: ReconciliationViewModel
    let storedModel: PricingModelResponse
    var onApply: (([ToolPrice], MCPService.ToolMismatch) -> Void)?
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
                    Button("Done") { dismiss() }
                }
            }
        }
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
                if !mismatch.newTools.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("\(mismatch.newTools.count) New Tools", systemImage: "plus.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.green)

                        ForEach(mismatch.newTools, id: \.name) { tool in
                            HStack {
                                Text(tool.name)
                                    .font(.caption.monospaced())
                                Spacer()
                                Text("will be added at 0 sats")
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
                if viewModel.repairedOrphanCount > 0 {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Repaired \(viewModel.repairedOrphanCount) orphan tool UUID\(viewModel.repairedOrphanCount == 1 ? "" : "s")")
                                .font(.caption.bold())
                            Text("Earlier Reconcile runs derived UUIDs from the slug-prefixed protocol name. The wheel looks up by the bare capability, so those rows were unreachable. Saving this reconciliation re-keys them to the canonical UUID; prices and multipliers are preserved.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }

                let newToolNames = Set(mismatch.newTools.map(\.name))
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

                HStack {
                    Button("Dismiss") { dismiss() }
                        .buttonStyle(.bordered)

                    Button {
                        onApply?(suggested, mismatch)
                        applied = true
                    } label: {
                        Label("Apply", systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
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
            Button("Done") { dismiss() }
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
