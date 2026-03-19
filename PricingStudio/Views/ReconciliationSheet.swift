import SwiftUI

struct ReconciliationSheet: View {
    @Bindable var viewModel: ReconciliationViewModel
    let storedModel: PricingModelResponse
    var onApply: (([ToolPrice], MCPService.ToolMismatch) -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isDetecting {
                    detectingPhase
                } else if viewModel.isReconciling {
                    processingPhase
                } else if let suggested = viewModel.suggestedTools, let mismatch = viewModel.mismatch {
                    reviewPhase(suggested: suggested, mismatch: mismatch)
                } else if let mismatch = viewModel.mismatch, mismatch.hasMismatch {
                    diagnosticPhase(mismatch: mismatch)
                } else if let error = viewModel.error {
                    errorPhase(error)
                } else {
                    ProgressView("Preparing...")
                }
            }
            .navigationTitle("Reconcile Tools")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Phase 1: Detecting

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

    // MARK: - Phase 2: Diagnostic

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
                                Text("unpriced")
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
                                Text("\(tool.priceSats) sats")
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
                    viewModel.requestReconciliation(storedModel: storedModel)
                } label: {
                    Label("Reconcile with AI", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
        }
    }

    // MARK: - Phase 3: Processing

    private var processingPhase: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)

            providerBadge

            Text("Generating reconciled pricing...")
                .font(.headline)

            if !viewModel.reconciliationText.isEmpty {
                ScrollView {
                    Text(viewModel.reconciliationText)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .frame(maxHeight: 200)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding()
    }

    // MARK: - Phase 4: Review

    @ViewBuilder
    private func reviewPhase(suggested: [ToolPrice], mismatch: MCPService.ToolMismatch) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                providerBadge

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
                        dismiss()
                    } label: {
                        Label("Apply as Edits", systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
    }

    // MARK: - Error

    private func errorPhase(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Reconciliation Issue", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Dismiss") { dismiss() }
                .buttonStyle(.bordered)
        }
    }

    // MARK: - Helpers

    private var providerBadge: some View {
        Text(viewModel.providerName)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                viewModel.providerName == "Grok" ? Color.orange.opacity(0.15) : Color.purple.opacity(0.15),
                in: Capsule()
            )
            .foregroundStyle(viewModel.providerName == "Grok" ? .orange : .purple)
    }

    private func categoryDisplayName(_ category: String) -> String {
        switch category {
        case "free": return "Free"
        case "auth": return "Auth & Balance"
        case "read": return "Read (1 sat)"
        case "write": return "Write (5 sats)"
        case "heavy": return "Heavy (10 sats)"
        case "restricted": return "Restricted (Operator Only)"
        default: return category.capitalized
        }
    }
}
