import SwiftUI

struct PricingDetailView: View {
    let target: any PricingTarget
    @Bindable var viewModel: PricingViewModel
    @State private var isEditingPipeline = false
    @State private var saveError: String?
    @State private var showSaveSuccess = false

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle:
                ProgressView()
                    .task { viewModel.startLoading(for: target) }

            case .loading(let step):
                ConnectionStatusView(step: step, onCancel: { viewModel.cancel() })

            case .loaded(let model):
                loadedContent(model)

            case .error(let message):
                errorContent(message)

            case .cancelled:
                ContentUnavailableView {
                    Label("Loading Cancelled", systemImage: "stop.circle")
                } description: {
                    Text("The connection was cancelled before it could complete.")
                } actions: {
                    Button("Retry") {
                        viewModel.retry(for: target)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle(target.displayName)
        .onChange(of: target.npub) { _, _ in
            viewModel.startLoading(for: target)
        }
    }

    private var editSummary: String {
        var parts: [String] = []
        if !viewModel.localEdits.isEmpty {
            let n = viewModel.localEdits.count
            parts.append("\(n) tool \(n == 1 ? "edit" : "edits")")
        }
        if viewModel.hasPipelineEdits {
            parts.append("pipeline changes")
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func loadedContent(_ model: PricingModelResponse) -> some View {
        if model.status == "ok", let tools = model.tools {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if let name = model.name {
                            modelHeader(name: name, isActive: model.isActive ?? false, member: viewModel.memberRecord, source: model.source)
                        }

                        pipelineSection(model.pipeline ?? [])

                        ToolPriceListView(tools: tools, viewModel: viewModel, target: target)
                    }
                    .padding()
                }
                .refreshable {
                    viewModel.retry(for: target)
                }

                if viewModel.hasEdits {
                    unifiedSaveBar
                }
            }
            .alert("Save Failed", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK") { saveError = nil }
            } message: {
                if let saveError {
                    Text(saveError)
                }
            }
        } else {
            ContentUnavailableView(
                "No Pricing Model",
                systemImage: "tag.slash",
                description: Text("This entity hasn't published a pricing model yet.")
            )
        }
    }

    private var unifiedSaveBar: some View {
        HStack {
            Text(editSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if showSaveSuccess {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Button("Reset All") {
                viewModel.resetAllEdits()
                isEditingPipeline = false
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Save to Operator") {
                Task {
                    do {
                        try await viewModel.savePricing(for: target)
                        isEditingPipeline = false
                        showSaveSuccess = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            showSaveSuccess = false
                        }
                    } catch {
                        saveError = error.localizedDescription
                    }
                }
            }
            .font(.caption)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func pipelineSection(_ serverPipeline: [PipelineStep]) -> some View {
        HStack {
            Spacer()
            if isEditingPipeline {
                Button("Done") {
                    isEditingPipeline = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button {
                    viewModel.beginPipelineEditing()
                    isEditingPipeline = true
                } label: {
                    Label("Edit Pipeline", systemImage: "pencil")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }

        PipelineView(
            steps: isEditingPipeline
                ? Binding(
                    get: { viewModel.localPipeline ?? serverPipeline },
                    set: { viewModel.localPipeline = $0 }
                )
                : .constant(serverPipeline),
            isEditing: isEditingPipeline
        )
    }

    @ViewBuilder
    private func modelHeader(name: String, isActive: Bool, member: MemberRecord?, source: PricingSource) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.title2.bold())

                    if let member {
                        MemberInfoButton(member: member)
                    }
                }
                HStack(spacing: 12) {
                    if isActive {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    }
                    Label(
                        source == .stored ? "Stored" : "Synthesized",
                        systemImage: source == .stored ? "externaldrive.fill" : "wand.and.stars"
                    )
                    .font(.caption)
                    .foregroundStyle(source == .stored ? .blue : .orange)
                    if let age = viewModel.cacheAgeSecs {
                        Text("\(age)s ago")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
            }
            Spacer()
            Button {
                viewModel.forceRefresh(for: target)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.subheadline)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func errorContent(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Connection Error", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") {
                viewModel.retry(for: target)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Member Info Popover

private struct MemberInfoButton: View {
    let member: MemberRecord
    @State private var showingInfo = false

    var body: some View {
        Button {
            showingInfo.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingInfo) {
            memberInfoContent
                .presentationCompactAdaptation(.popover)
        }
    }

    private var memberInfoContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(member.displayName)
                .font(.headline)

            if let notes = member.notes, !notes.isEmpty {
                Text(notes)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if let service = member.services?.first {
                Label(service.name, systemImage: "server.rack")
                    .font(.caption)
                if let desc = service.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let since = member.memberSince {
                Label("Member since \(since)", systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Label(member.role.capitalized, systemImage: "person.fill")
                Label(member.status.capitalized, systemImage: "circle.fill")
                    .foregroundStyle(member.status == "active" ? .green : .secondary)
            }
            .font(.caption)
        }
        .padding()
        .frame(idealWidth: 300)
    }
}
