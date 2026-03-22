import SwiftUI

struct PricingDetailView: View {
    let target: any PricingTarget
    @Bindable var viewModel: PricingViewModel
    @State private var isEditingPipeline = false
    @State private var saveError: String?
    @State private var showSaveSuccess = false
    @State private var showingSaveConfirmation = false
    @State private var showingDiff = false
    @State private var showingReconciliation = false
    @State private var showingReconcileConfirmation = false
    @State private var reconciliationVM = ReconciliationViewModel()

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

            case .notRegistered:
                notRegisteredContent

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
        .onAppear {
            // Ensure we're showing the right target's data — shared VM may
            // still hold data from a previously viewed operator/authority
            if viewModel.currentOperatorNpub != target.npub {
                viewModel.startLoading(for: target)
            }
        }
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
        if !viewModel.localRemovals.isEmpty {
            let n = viewModel.localRemovals.count
            parts.append("\(n) \(n == 1 ? "removal" : "removals")")
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

                        if let endpoint = target.mcpEndpointURL {
                            NotarizationStatusView(operatorNpub: target.npub, endpointURL: endpoint)
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
            .sheet(isPresented: $showingDiff) {
                NavigationStack {
                    PricingDiffView(
                        modelA: model,
                        modelB: viewModel.mergedPreview(from: model),
                        labelA: "Current",
                        labelB: "With Edits"
                    )
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingDiff = false }
                        }
                    }
                }
            }
            .sheet(isPresented: $showingReconciliation) {
                ReconciliationSheet(
                    viewModel: reconciliationVM,
                    storedModel: model,
                    onApply: { suggested, mismatch in
                        viewModel.applyReconciliation(suggestedTools: suggested, mismatch: mismatch)
                    }
                )
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

            Button("Compare") {
                showingDiff = true
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Reset All") {
                viewModel.resetAllEdits()
                isEditingPipeline = false
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Save to Operator") {
                showingSaveConfirmation = true
            }
            .accessibilityIdentifier("applyButton")
            .font(.caption)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .confirmationDialog(
                "Save Changes",
                isPresented: $showingSaveConfirmation,
                titleVisibility: .visible
            ) {
                Button("Save to \(target.displayName)") {
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
                .accessibilityIdentifier("confirmApplyButton")
                Button("Cancel", role: .cancel) { }
                    .accessibilityIdentifier("cancelApplyButton")
            } message: {
                Text("This will overwrite the operator's active pricing model with your \(editSummary). This action cannot be undone.")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func pipelineSection(_ serverPipeline: [PipelineStep]) -> some View {
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
                if let versions = viewModel.serviceVersions {
                    ServiceVersionsRow(versions: versions)
                }
            }
            Spacer()
            if source == .stored {
                if isEditingPipeline {
                    Button("Done Editing") {
                        isEditingPipeline = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button {
                        viewModel.beginPipelineEditing()
                        isEditingPipeline = true
                    } label: {
                        Label("Manage Constraints", systemImage: "pencil")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button {
                    showingReconcileConfirmation = true
                } label: {
                    Label("Reconcile", systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .alert("Reconcile Tools", isPresented: $showingReconcileConfirmation) {
                    Button("Cancel", role: .cancel) { }
                    Button("OK") {
                        reconciliationVM = ReconciliationViewModel()
                        showingReconciliation = true
                        Task {
                            if let (url, token) = try? await viewModel.resolveEndpointAndToken(for: target),
                               let model = viewModel.pricingModel {
                                reconciliationVM.detectMismatch(
                                    endpointURL: url,
                                    bearerToken: token,
                                    storedModel: model
                                )
                            }
                        }
                    }
                } message: {
                    Text("Reconcile compares your stored pricing model against the live MCP endpoint and suggests updates for new, changed, or removed tools.\n\nThe suggestions are advisory only — no changes are applied unless you choose to accept them.")
                }
            }
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

    private var notRegisteredContent: some View {
        ContentUnavailableView {
            Label("Not Registered", systemImage: "person.crop.circle.badge.questionmark")
        } description: {
            VStack(alignment: .leading, spacing: 12) {
                Text("**\(target.displayName)** is not yet registered with the DPYC community.")

                Text("To register this operator:")
                    .fontWeight(.medium)

                VStack(alignment: .leading, spacing: 6) {
                    Label("Connect to a sponsoring Authority's MCP endpoint", systemImage: "1.circle")
                    Label("Authenticate via Horizon OAuth", systemImage: "2.circle")
                    Label("The Authority calls register_operator with this npub", systemImage: "3.circle")
                    Label("Retry here once registration is confirmed", systemImage: "4.circle")
                }
                .font(.subheadline)
            }
        } actions: {
            VStack(spacing: 12) {
                Text(target.npub)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Button("Retry") {
                    viewModel.retry(for: target)
                }
                .buttonStyle(.borderedProminent)
            }
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

// MARK: - Service Versions Row

private struct ServiceVersionsRow: View {
    let versions: [String: String]
    @State private var expanded = false

    /// Display order: show the MCP package first, then tollbooth_dpyc, then others.
    private var sortedVersions: [(key: String, value: String)] {
        let priority = ["excalibur_mcp", "tollbooth_authority", "tollbooth_dpyc", "fastmcp"]
        return versions.sorted { a, b in
            let ai = priority.firstIndex(of: a.key) ?? priority.count
            let bi = priority.firstIndex(of: b.key) ?? priority.count
            return ai < bi
        }
    }

    /// Short label for the primary package version.
    private var primaryVersion: (name: String, version: String)? {
        let preferred = ["excalibur_mcp", "tollbooth_authority"]
        for key in preferred {
            if let v = versions[key] {
                return (key, v)
            }
        }
        return sortedVersions.first.map { ($0.key, $0.value) }
    }

    var body: some View {
        if let primary = primaryVersion {
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "shippingbox")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(formatName(primary.name)) \(primary.version)")
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(.secondary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sortedVersions, id: \.key) { entry in
                        HStack(spacing: 6) {
                            Text(formatName(entry.key))
                                .frame(width: 120, alignment: .trailing)
                                .foregroundStyle(.secondary)
                            Text(entry.value)
                                .monospaced()
                        }
                        .font(.caption2)
                    }
                }
                .padding(.leading, 20)
            }
        }
    }

    private func formatName(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
    }
}
