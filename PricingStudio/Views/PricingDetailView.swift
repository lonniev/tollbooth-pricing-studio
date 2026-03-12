import SwiftUI

struct PricingDetailView: View {
    let op: Operator
    @Bindable var viewModel: PricingViewModel

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle:
                ProgressView()
                    .task { viewModel.loadPreview(for: op) }

            case .loading(let step):
                ConnectionStatusView(step: step)

            case .loaded(let model):
                loadedContent(model)

            case .error(let message):
                errorContent(message)
            }
        }
        .navigationTitle(op.displayName)
        .onChange(of: op) { _, newOp in
            viewModel.loadPreview(for: newOp)
        }
    }

    @ViewBuilder
    private func loadedContent(_ model: PricingModelResponse) -> some View {
        if model.status == "ok", let tools = model.tools {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let name = model.name {
                        modelHeader(name: name, isActive: model.isActive ?? false)
                    }

                    ToolPriceListView(tools: tools)

                    if let pipeline = model.pipeline, !pipeline.isEmpty {
                        PipelineView(steps: pipeline)
                    }
                }
                .padding()
            }
            .refreshable {
                await viewModel.retry(for: op)
            }
        } else {
            ContentUnavailableView(
                "No Pricing Model",
                systemImage: "tag.slash",
                description: Text("This operator hasn't published a pricing model yet.")
            )
        }
    }

    private func modelHeader(name: String, isActive: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.title2.bold())
                if isActive {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                }
            }
            Spacer()
        }
    }

    private func errorContent(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Connection Error", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") {
                Task { await viewModel.retry(for: op) }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
