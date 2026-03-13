import SwiftUI

struct PricingDetailView: View {
    let target: any PricingTarget
    @Bindable var viewModel: PricingViewModel

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
            }
        }
        .navigationTitle(target.displayName)
        .onChange(of: target.npub) { _, _ in
            viewModel.startLoading(for: target)
        }
    }

    @ViewBuilder
    private func loadedContent(_ model: PricingModelResponse) -> some View {
        if model.status == "ok", let tools = model.tools {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let name = model.name {
                        modelHeader(name: name, isActive: model.isActive ?? false, member: viewModel.memberRecord)
                    }

                    ToolPriceListView(tools: tools)

                    if let pipeline = model.pipeline, !pipeline.isEmpty {
                        PipelineView(steps: pipeline)
                    }
                }
                .padding()
            }
            .refreshable {
                viewModel.retry(for: target)
            }
        } else {
            ContentUnavailableView(
                "No Pricing Model",
                systemImage: "tag.slash",
                description: Text("This entity hasn't published a pricing model yet.")
            )
        }
    }

    @ViewBuilder
    private func modelHeader(name: String, isActive: Bool, member: MemberRecord?) -> some View {
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
