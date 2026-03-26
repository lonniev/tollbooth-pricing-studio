import SwiftUI
import SwiftData

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
    @State private var showingEditRegistration = false
    @State private var showingDeregisterConfirm = false
    @State private var deregisterError: String?
    @State private var onboardingStatus: MCPService.OnboardingStatus?
    @State private var onboardingLoading = false
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle:
                ProgressView()

            case .loading(let step):
                ConnectionStatusView(step: step, onCancel: { viewModel.cancel() })

            case .loaded(let model):
                loadedContent(model)

            case .error(let message):
                errorContent(message)

            case .notRegistered:
                notRegisteredContent

            case .registeredNotConfigured:
                registeredNotConfiguredContent

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
            // still hold data from a previously viewed operator/authority.
            // Also restart if stuck in .loading from a previous cancelled navigation.
            let needsLoad: Bool = {
                if case .idle = viewModel.state { return true }
                if case .loading = viewModel.state { return true }
                if case .cancelled = viewModel.state { return true }
                if viewModel.currentOperatorNpub != target.npub { return true }
                return false
            }()
            if needsLoad {
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
            Menu {
                Button {
                    viewModel.forceRefresh(for: target)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                if target is Operator {
                    Divider()
                    Button {
                        showingEditRegistration = true
                    } label: {
                        Label("Edit Registration", systemImage: "pencil")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showingDeregisterConfirm = true
                    } label: {
                        Label("Deregister Operator", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.subheadline)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .sheet(isPresented: $showingEditRegistration) {
                EditOperatorRegistrationSheet(operatorTarget: target)
            }
            .confirmationDialog(
                "Deregister Operator",
                isPresented: $showingDeregisterConfirm,
                titleVisibility: .visible
            ) {
                Button("Deregister \(target.displayName)", role: .destructive) {
                    Task { await deregisterOperator() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This will remove the operator from the DPYC community registry. The operator will need to re-register with an Authority to resume service.")
            }
            .alert("Deregister Failed", isPresented: Binding(
                get: { deregisterError != nil },
                set: { if !$0 { deregisterError = nil } }
            )) {
                Button("OK") { deregisterError = nil }
            } message: {
                if let deregisterError { Text(deregisterError) }
            }
        }
    }

    private func errorContent(_ message: String) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48))
                    .foregroundStyle(.yellow)

                Text("Unable to Load")
                    .font(.title2.bold())

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)

                if let url = target.mcpEndpointURL, !url.isEmpty {
                    Text(url)
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }

                // Show onboarding checklist if available
                if target is Operator, target.mcpEndpointURL != nil {
                    if onboardingLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Checking configuration...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let status = onboardingStatus {
                        onboardingChecklist(status)
                    }

                    if let courierStatus {
                        Text(courierStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 400)
                            .padding(8)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                // Actions
                HStack(spacing: 12) {
                    Button("Retry") {
                        viewModel.retry(for: target)
                    }
                    .buttonStyle(.borderedProminent)

                    if target is Operator {
                        Menu {
                            Button {
                                showingAdoptionRequest = true
                            } label: {
                                Label("Register with Authority", systemImage: "building.columns")
                            }
                            Button {
                                showingEditRegistration = true
                            } label: {
                                Label("Edit Registration", systemImage: "pencil")
                            }
                            if (target as? Operator)?.authorityNpub != nil {
                                Divider()
                                Button(role: .destructive) {
                                    showingDeregisterConfirm = true
                                } label: {
                                    Label("Deregister", systemImage: "trash")
                                }
                            }
                        } label: {
                            Label("Manage", systemImage: "ellipsis.circle")
                        }
                        .buttonStyle(.bordered)
                        .sheet(isPresented: $showingEditRegistration) {
                            EditOperatorRegistrationSheet(operatorTarget: target)
                        }
                    }
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if target is Operator, target.mcpEndpointURL != nil, onboardingStatus == nil {
                await loadOnboardingStatus()
            }
        }
    }

    @State private var showingAdoptionRequest = false

    private var registeredNotConfiguredContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)

                Text("Registered")
                    .font(.title2.bold())

                Text("**\(target.displayName)** is registered in the DPYC community but needs configuration.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)

                if let url = target.mcpEndpointURL, !url.isEmpty {
                    Text(url)
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }

                // Live onboarding status
                if onboardingLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking configuration...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let status = onboardingStatus {
                    onboardingChecklist(status)
                } else {
                    // Fallback static checklist
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Operator is in the community registry", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Label("Checking operator configuration...", systemImage: "circle.dotted")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }

                if let courierStatus {
                    Text(courierStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                        .padding(8)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }

                Text(target.npub)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)

                HStack(spacing: 12) {
                    Button {
                        showingEditRegistration = true
                    } label: {
                        Label("Edit Registration", systemImage: "pencil.circle")
                    }
                    .buttonStyle(.bordered)

                    Button("Check Again") {
                        viewModel.retry(for: target)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .sheet(isPresented: $showingEditRegistration) {
                    EditOperatorRegistrationSheet(operatorTarget: target)
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await loadOnboardingStatus()
        }
    }

    @ViewBuilder
    private func onboardingChecklist(_ status: MCPService.OnboardingStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Operator is in the community registry", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.subheadline)

            ForEach(status.configured, id: \.field) { field in
                Label("\(fieldLabel(field.field))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)
            }

            if !status.missing.isEmpty {
                Divider()

                let hasSecrets = status.missing.contains { $0.category == "secret" }
                let hasAuthority = status.missing.contains { $0.category == "authority" }

                ForEach(status.missing, id: \.field) { field in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: categoryIcon(field.category))
                            .foregroundStyle(categoryColor(field.category))
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fieldLabel(field.field))
                                .font(.subheadline)
                                .foregroundStyle(categoryColor(field.category))
                            if let how = field.how {
                                Text(how)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Divider()

                // Actionable buttons based on what's missing
                VStack(spacing: 10) {
                    if hasAuthority {
                        Button {
                            Task { await loadOnboardingStatus() }
                        } label: {
                            Label("Refresh Config from Authority", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.blue)
                    }

                    if hasSecrets {
                        let missingSecretNames = status.missing
                            .filter { $0.category == "secret" }
                            .map { fieldLabel($0.field) }
                            .joined(separator: ", ")

                        Button {
                            Task { await requestSecureCourier() }
                        } label: {
                            Label("Deliver Secrets via Secure Courier", systemImage: "lock.shield")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.orange)

                        Text("Opens a Secure Courier channel so you can deliver: \(missingSecretNames)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if status.ready {
                Divider()
                Label("Operator is fully configured and ready to serve", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
        }
    }

    @State private var courierStatus: String?

    private func requestSecureCourier() async {
        guard let endpoint = target.mcpEndpointURL,
              let endpointURL = URL(string: endpoint) else {
            courierStatus = "No MCP endpoint configured"
            return
        }

        do {
            let (_, token) = try await viewModel.resolveEndpointAndToken(for: target)
            let result = try await MCPService().callRequestCredentialChannel(
                endpointURL: endpointURL,
                bearerToken: token,
                senderNpub: target.npub
            )
            courierStatus = result
        } catch {
            courierStatus = "Failed: \(error.localizedDescription)"
        }
    }

    private func fieldLabel(_ field: String) -> String {
        field.replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private func categoryIcon(_ category: String) -> String {
        switch category {
        case "authority": return "building.columns"
        case "secret": return "lock.shield"
        case "identity": return "key"
        default: return "circle"
        }
    }

    private func categoryColor(_ category: String) -> Color {
        switch category {
        case "authority": return .blue
        case "secret": return .orange
        case "identity": return .purple
        default: return .secondary
        }
    }

    private func loadOnboardingStatus() async {
        guard let endpoint = target.mcpEndpointURL,
              let endpointURL = URL(string: endpoint) else { return }

        onboardingLoading = true
        defer { onboardingLoading = false }

        do {
            let (_, token) = try await viewModel.resolveEndpointAndToken(for: target)
            onboardingStatus = try await MCPService().callGetOnboardingStatus(
                endpointURL: endpointURL,
                bearerToken: token
            )
        } catch {
            // Silently fail — view falls back to static checklist
            TrafficLogger.shared.log(.error, label: "Onboarding Status", detail: error.localizedDescription)
        }
    }

    private var notRegisteredContent: some View {
        VStack(spacing: 24) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("Not Registered")
                .font(.title2.bold())

            Text("**\(target.displayName)** is not yet registered with the DPYC community. Select an Authority to register with.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            VStack(spacing: 4) {
                Text(target.npub)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                if let url = target.mcpEndpointURL, !url.isEmpty {
                    Text(url)
                        .font(.caption2)
                        .monospaced()
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                } else {
                    Label("No MCP endpoint configured", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            HStack(spacing: 12) {
                Button {
                    showingAdoptionRequest = true
                } label: {
                    Label("Register with Authority", systemImage: "building.columns")
                }
                .buttonStyle(.borderedProminent)

                Button("Retry") {
                    viewModel.retry(for: target)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingAdoptionRequest, onDismiss: {
            // If registration succeeded, go directly to registeredNotConfigured
            // (don't retry fetchPricing — the GitHub registry cache is stale)
            if let op = target as? Operator, op.authorityNpub != nil {
                viewModel.markRegisteredNotConfigured()
            }
        }) {
            RequestAdoptionSheet(operatorTarget: target, pricingVM: viewModel)
        }
    }

    private func deregisterOperator() async {
        guard let op = target as? Operator,
              let authNpub = op.authorityNpub else {
            // No authority link — just reset state
            viewModel.markNotRegistered()
            return
        }

        // Find the Authority's endpoint
        let authorities: [Authority] = (try? modelContext.fetch(FetchDescriptor<Authority>())) ?? []
        guard let authority = authorities.first(where: { $0.npub == authNpub }),
              let endpointString = authority.mcpEndpointURL,
              let endpointURL = URL(string: endpointString) else {
            // Can't reach Authority — just clear local link
            op.authorityNpub = nil
            try? modelContext.save()
            viewModel.markNotRegistered()
            return
        }

        let mcpService = MCPService()
        let oauthService = OAuthService()

        do {
            let host = endpointURL.host ?? authNpub
            let token: String
            if let bundle = KeychainService.loadTokenBundle(forPatron: op.npub, operator: host),
               !bundle.isExpired {
                token = bundle.accessToken
            } else {
                let bundle = try await oauthService.authenticate(mcpEndpoint: endpointURL)
                try? KeychainService.saveTokenBundle(bundle, forPatron: op.npub, operator: host)
                token = bundle.accessToken
            }

            _ = try await mcpService.callDeregisterOperator(
                endpointURL: endpointURL,
                bearerToken: token,
                operatorNpub: op.npub
            )
        } catch {
            deregisterError = "Registry removal failed: \(error.localizedDescription). Local link cleared."
        }

        op.authorityNpub = nil
        try? modelContext.save()
        viewModel.markNotRegistered()
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
