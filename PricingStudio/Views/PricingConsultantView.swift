import SwiftUI
import SwiftData

/// Conversational AI pricing campaign designer.
///
/// Interviews the operator via Claude to co-design a pricing model,
/// then offers an "Apply" button when the operator approves the JSON output.
struct PricingConsultantView: View {
    @Bindable var consultantVM: PricingConsultantViewModel
    let context: ConsultantContext
    let operatorNpub: String
    var onApplyJSON: ((String) -> Void)?
    /// Requests permanent deletion of the given campaign. The caller is responsible
    /// for presenting a confirmation alert before actually deleting.
    var onDeleteCampaign: ((Campaign) -> Void)?

    @Environment(\.modelContext) private var modelContext
    @State private var inputText = ""
    @State private var showingAPIKeySheet = false
    @State private var showingPromptEditor = false
    @State private var showingSaveSheet = false
    @State private var showingLoadSheet = false
    @State private var showingCompareSheet = false
    @State private var showingSecondOpinion = false
    @State private var showingFullScreen = false
    @State private var secondOpinionVM = SecondOpinionViewModel()
    @State private var saveName = ""
    @State private var publishingCampaign = false
    @State private var publishResult: String?
    @State private var showingPublishResult = false
    @State private var editingMessageIndex: Int?
    @State private var editedMessageText = ""
    @State private var showingForkSheet = false
    @State private var showingReshapePreview = false
    @State private var showingCloseConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if !consultantVM.messages.isEmpty {
                InterviewStepperView(
                    progress: consultantVM.interviewProgress,
                    viewingStageNumber: consultantVM.viewingStageNumber,
                    isStreaming: consultantVM.isStreaming,
                    onStageTapped: { stage in
                        consultantVM.revisitStage(stage)
                    }
                )
                .padding(.horizontal)
                .padding(.vertical, 8)

                InsightSummaryCard(progress: consultantVM.interviewProgress, projections: consultantVM.revenueProjections)
                    .padding(.horizontal)
                Divider()
            }

            // Stage-viewing banner
            if let viewing = consultantVM.viewingStageNumber,
               viewing != consultantVM.interviewProgress.stageNumber {
                let label = viewing <= InterviewProgress.stageLabels.count
                    ? InterviewProgress.stageLabels[viewing - 1]
                    : "Stage \(viewing)"
                HStack {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.orange)
                    Text("Viewing \(label)")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                    Spacer()
                    Button {
                        consultantVM.redoStage(viewing, context: context)
                    } label: {
                        Label("Redo Phase", systemImage: "arrow.counterclockwise")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.orange)
                    .disabled(consultantVM.isStreaming)
                    Button {
                        consultantVM.viewingStageNumber = nil
                    } label: {
                        Text("Current")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.08))
            }

            messageList
            Divider()

            if let json = consultantVM.extractedPipelineJSON {
                applyBar(json: json)
                Divider()
            }

            inputBar
        }
        .task {
            if consultantVM.promptSource == .notLoaded {
                await consultantVM.loadPrompt()
            }
        }
        .sheet(isPresented: $showingAPIKeySheet) {
            AssistantAPIKeySheet()
        }
        .fullScreenCover(isPresented: $showingFullScreen) {
            FullScreenInterviewView(
                consultantVM: consultantVM,
                context: context,
                operatorNpub: operatorNpub,
                onApplyJSON: onApplyJSON,
                onDismiss: { showingFullScreen = false }
            )
        }
        .sheet(isPresented: $showingPromptEditor) {
            PromptEditorSheet(consultantVM: consultantVM)
        }
        .sheet(isPresented: $showingLoadSheet) {
            CampaignListSheet(consultantVM: consultantVM, showingCompareSheet: $showingCompareSheet, operatorNpub: operatorNpub)
        }
        .sheet(isPresented: $showingCompareSheet) {
            CampaignComparisonSheet()
        }
        .sheet(isPresented: $showingSecondOpinion, onDismiss: {
            // Auto-feed Grok's suggestions to Claude so it can adjust the proposal
            if secondOpinionVM.hasSuggestedChanges,
               !secondOpinionVM.suggestedChangesText.isEmpty,
               !consultantVM.isStreaming {
                let feedbackPrompt = """
                A peer reviewer (\(secondOpinionVM.providerName)) has reviewed the campaign and offered this feedback:

                \(secondOpinionVM.suggestedChangesText)

                Please consider this feedback and adjust the pricing recommendation where the suggestions make sense within the DPYC economic model. Briefly note what you changed and why. Ignore any suggestions that conflict with DPYC principles.
                """
                consultantVM.send(feedbackPrompt, context: context)
            }
        }) {
            SecondOpinionSheet(
                viewModel: secondOpinionVM,
                onSave: { reviewText in
                    consultantVM.currentCampaign?.secondOpinionText = reviewText
                    if let ctx = consultantVM.currentCampaign {
                        ctx.updatedAt = Date()
                    }
                },
                onRerun: {
                    let summary = secondOpinionVM.buildCampaignSummary(
                        messages: consultantVM.messages,
                        progress: consultantVM.interviewProgress,
                        projections: consultantVM.revenueProjections,
                        pipelineJSON: consultantVM.extractedPipelineJSON,
                        operatorName: context.operatorName,
                        campaignName: consultantVM.currentCampaign?.name
                    )
                    secondOpinionVM.requestReview(summary: summary)
                },
                onRevise: { suggestedChanges in
                    // Fork the interview with the reviewer's suggestions
                    let revisionPrompt = """
                    The second-opinion reviewer (\(secondOpinionVM.providerName)) suggested these changes to the campaign:

                    \(suggestedChanges)

                    Please revise the pricing recommendation to incorporate these suggestions where they make sense within the DPYC economic model. Explain what you changed and why.
                    """
                    if let lastIdx = consultantVM.messages.indices.last {
                        consultantVM.forkFromMessage(at: lastIdx, newText: revisionPrompt, context: context)
                    }
                }
            )
        }
        .sheet(isPresented: $showingForkSheet) {
            ForkInterviewSheet(
                messageIndex: editingMessageIndex ?? 0,
                initialText: editedMessageText,
                isUserMessage: editingMessageIndex.flatMap { consultantVM.messages.indices.contains($0) ? consultantVM.messages[$0].role == .user : false } ?? false,
                onFork: { newText in
                    guard let idx = editingMessageIndex else { return }
                    consultantVM.forkFromMessage(at: idx, newText: newText, context: context)
                    editingMessageIndex = nil
                    editedMessageText = ""
                },
                onCancel: {
                    editingMessageIndex = nil
                    editedMessageText = ""
                }
            )
        }
        .sheet(isPresented: $showingReshapePreview) {
            ReshapePreviewSheet(
                messages: consultantVM.messages,
                stages: consultantVM.pendingReshape ?? [],
                onAccept: {
                    consultantVM.acceptReshape(
                        context: modelContext,
                        consultantContext: context,
                        rerunRecommendation: true
                    )
                    showingReshapePreview = false
                },
                onDiscard: {
                    consultantVM.discardReshape()
                    showingReshapePreview = false
                }
            )
        }
        .onChange(of: consultantVM.pendingReshape) { _, newValue in
            if newValue != nil {
                showingReshapePreview = true
            }
        }
        .alert("Reshape Failed", isPresented: .init(
            get: { consultantVM.reshapeError != nil },
            set: { if !$0 { consultantVM.reshapeError = nil } }
        )) {
            Button("OK") { consultantVM.reshapeError = nil }
        } message: {
            Text(consultantVM.reshapeError ?? "")
        }
        .alert("Save Campaign", isPresented: $showingSaveSheet) {
            TextField("Campaign name", text: $saveName)
            Button("Save") {
                let name = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                consultantVM.saveCampaign(
                    name: name,
                    operatorNpub: operatorNpub,
                    operatorDisplayName: context.operatorName ?? "Unknown",
                    context: modelContext
                )
                saveName = ""
            }
            Button("Cancel", role: .cancel) { saveName = "" }
        } message: {
            if consultantVM.currentCampaign != nil {
                Text("Update the saved campaign name, or keep the current one.")
            } else {
                Text("Give this campaign a name so you can resume it later.")
            }
        }
        .alert("Publish Campaign", isPresented: $showingPublishResult) {
            Button("OK") { publishResult = nil }
        } message: {
            Text(publishResult ?? "")
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack {
            if let campaign = consultantVM.currentCampaign {
                Text(campaign.name)
                    .font(.headline)
                    .lineLimit(1)
            } else {
                Label("Pricing Campaign Designer", systemImage: "wand.and.stars")
                    .font(.headline)
            }

            promptSourceBadge

            // Philosophy badge
            if let philosophy = consultantVM.interviewProgress.insights.philosophy {
                philosophyBadge(philosophy)
            }

            Spacer()

            // ── File: load / save / reconcile ──
            Button {
                showingLoadSheet = true
            } label: {
                Label("Load", systemImage: "folder")
                    .labelStyle(.iconOnly)
            }

            Button {
                if let campaign = consultantVM.currentCampaign {
                    saveName = campaign.name
                } else {
                    let operatorName = context.operatorName ?? "Campaign"
                    let dateStr = Date().formatted(.dateTime.month(.abbreviated).day())
                    saveName = "\(operatorName) — \(dateStr)"
                }
                showingSaveSheet = true
            } label: {
                Label("Save", systemImage: "tray.and.arrow.down")
                    .labelStyle(.iconOnly)
            }
            .disabled(consultantVM.messages.isEmpty)

            Button {
                consultantVM.aiReshape()
            } label: {
                if consultantVM.isReshaping {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Reconcile Stages", systemImage: "arrow.triangle.2.circlepath")
                        .labelStyle(.iconOnly)
                }
            }
            .disabled(consultantVM.messages.isEmpty || consultantVM.isReshaping)
            .help("AI re-classify messages into interview stages and rerun recommendation")

            Divider().frame(height: 16)

            // ── Share: export transcript / share campaign / publish ──
            if !consultantVM.messages.isEmpty {
                ShareLink(
                    item: consultantVM.exportTranscript(),
                    subject: Text("Pricing Interview"),
                    message: Text("Interview transcript from Pricing Studio")
                ) {
                    Label("Export Transcript", systemImage: "doc.plaintext")
                        .labelStyle(.iconOnly)
                }
            }

            ShareLink(
                item: consultantVM.currentCampaign?.exportMarkdown() ?? "",
                subject: Text(consultantVM.currentCampaign?.name ?? "Campaign"),
                message: Text("Pricing campaign from DPYC Pricing Studio")
            ) {
                Label("Share Campaign", systemImage: "square.and.arrow.up")
                    .labelStyle(.iconOnly)
            }
            .disabled(consultantVM.currentCampaign == nil)

            Button {
                Task { await publishCampaign() }
            } label: {
                if publishingCampaign {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Publish", systemImage: "globe")
                        .labelStyle(.iconOnly)
                }
            }
            .disabled(consultantVM.currentCampaign == nil || publishingCampaign)
            .help("Publish to DPYC Community")

            Divider().frame(height: 16)

            // ── Review: second opinion ──
            if !consultantVM.messages.isEmpty {
                let canReview = consultantVM.interviewProgress.stageNumber >= 6
                    || consultantVM.currentCampaign?.secondOpinionText != nil
                Button {
                    if let existingReview = consultantVM.currentCampaign?.secondOpinionText,
                       !existingReview.isEmpty {
                        secondOpinionVM.loadExistingReview(text: existingReview)
                    } else {
                        let summary = secondOpinionVM.buildCampaignSummary(
                            messages: consultantVM.messages,
                            progress: consultantVM.interviewProgress,
                            projections: consultantVM.revenueProjections,
                            pipelineJSON: consultantVM.extractedPipelineJSON,
                            operatorName: context.operatorName,
                            campaignName: consultantVM.currentCampaign?.name
                        )
                        secondOpinionVM.requestReview(summary: summary)
                    }
                    showingSecondOpinion = true
                } label: {
                    Label("Second Opinion", systemImage: "person.2.wave.2")
                        .labelStyle(.iconOnly)
                }
                .disabled(!canReview || consultantVM.isStreaming)
                .help(canReview
                    ? "Get a peer review from \(secondOpinionVM.providerName)"
                    : "Available after Synthesis stage (stage 6 of 6)")
            }

            Divider().frame(height: 16)

            // ── Destructive: delete / close ──
            if let campaign = consultantVM.currentCampaign, onDeleteCampaign != nil {
                Button {
                    onDeleteCampaign?(campaign)
                } label: {
                    Label("Delete", systemImage: "trash")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.red)
                }
            }

            Button {
                showingCloseConfirmation = true
            } label: {
                Label("Close", systemImage: "xmark.circle")
                    .labelStyle(.iconOnly)
            }
            .disabled(consultantVM.messages.isEmpty)
            .confirmationDialog(
                "Close Interview",
                isPresented: $showingCloseConfirmation,
                titleVisibility: .visible
            ) {
                Button("Close Without Saving", role: .destructive) {
                    consultantVM.clear()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This will discard the current interview. Any unsaved changes will be lost.")
            }

            Button {
                showingFullScreen = true
            } label: {
                Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                    .labelStyle(.iconOnly)
            }
            .disabled(consultantVM.messages.isEmpty)

            // ── Deploy (far right, separated by spacer) ──
            if let json = consultantVM.extractedPipelineJSON
                ?? consultantVM.proposal.pipelineJSON {
                Spacer().frame(width: 16)
                Button {
                    onApplyJSON?(json)
                } label: {
                    Label("Deploy", systemImage: "banknote.fill")
                        .labelStyle(.iconOnly)
                }
                .disabled(onApplyJSON == nil)
                .help("Deploy campaign to operator")
            }

        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func philosophyBadge(_ philosophy: String) -> some View {
        let (icon, color, label): (String, Color, String) = switch philosophy.lowercased() {
        case "capitalist":
            ("chart.line.uptrend.xyaxis", .green, "Capitalist")
        case "charitable":
            ("heart.fill", .pink, "Charitable")
        default:
            ("scale.3d", .blue, "Balanced")
        }
        Label(label, systemImage: icon)
            .font(.caption2)
            .foregroundStyle(color)
    }

    @ViewBuilder
    private var promptSourceBadge: some View {
        switch consultantVM.promptSource {
        case .community:
            Label("Community", systemImage: "globe")
                .font(.caption2)
                .foregroundStyle(.green)
        case .cached:
            Label("Cached", systemImage: "arrow.down.circle")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .edited:
            Label("Edited", systemImage: "pencil.circle")
                .font(.caption2)
                .foregroundStyle(.blue)
        case .fallback:
            Label("Default", systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.yellow)
        case .notLoaded:
            ProgressView()
                .controlSize(.mini)
        }
    }

    // MARK: - Message List

    @ViewBuilder
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if consultantVM.displayedMessages.isEmpty {
                        emptyState
                    } else {
                        // Show only the current stage's conversation
                        ForEach(consultantVM.displayedMessages) { message in
                            bubble(message)
                                .id(message.id)
                        }
                    }

                    // Stage 6 buffering indicator
                    if consultantVM.isStreaming && consultantVM.interviewProgress.stageNumber == 6 {
                        VStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.regular)
                            Text("Preparing your recommendation...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("The full pricing proposal will appear once ready.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                        .id("recommendation-loading")
                    }
                }
                .padding()
            }
            .onChange(of: consultantVM.displayedMessages.last?.content) { _, _ in
                if let lastId = consultantVM.displayedMessages.last?.id {
                    withAnimation {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }
    }


    @ViewBuilder
    private func stageSectionHeader(stage: Int) -> some View {
        let label = stage > 0 && stage <= InterviewProgress.stageLabels.count
            ? InterviewProgress.stageLabels[stage - 1]
            : "Stage \(stage)"
        let icon = stageIcon(stage)
        let hasMessages = !(consultantVM.stageMessages[stage] ?? []).isEmpty

        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            Text("Phase \(stage): \(label)")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            VStack { Divider() }
            if hasMessages && !consultantVM.isStreaming {
                Button {
                    consultantVM.redoStage(stage, context: context)
                } label: {
                    Label("Redo", systemImage: "arrow.counterclockwise")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(.orange)
                .help("Re-interview this phase from scratch")
            }
        }
        .padding(.top, stage > 1 ? 16 : 4)
    }

    private func stageIcon(_ stage: Int) -> String {
        switch stage {
        case 1: return "hammer"
        case 2: return "chart.bar"
        case 3: return "dollarsign.circle"
        case 4: return "gauge.with.dots.needle.bottom.50percent"
        case 5: return "slider.horizontal.3"
        case 6: return "star.fill"
        default: return "circle"
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if KeychainService.loadAnthropicAPIKey() == nil {
            VStack(spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("API Key Required")
                    .font(.headline)
                Text("Set up your Anthropic API key to start designing pricing campaigns with AI.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    showingAPIKeySheet = true
                } label: {
                    Label("Set Up API Key", systemImage: "gearshape")
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        } else {
            VStack(spacing: 16) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Pricing Campaign Designer")
                    .font(.title3.bold())
                Text("Start a new interview or load a saved campaign. The consultant will guide you through designing a pricing campaign with constraint pipeline.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)

                VStack(alignment: .leading, spacing: 4) {
                    Label("Inventory — what tools you offer", systemImage: "1.circle")
                    Label("Demand — expected usage patterns", systemImage: "2.circle")
                    Label("Value — what callers will pay", systemImage: "3.circle")
                    Label("Cost — what it costs you to serve", systemImage: "4.circle")
                    Label("Constraints — promotional mechanics", systemImage: "5.circle")
                    Label("Recommendation — draft + refine", systemImage: "6.circle")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)

                HStack(spacing: 16) {
                    Button {
                        consultantVM.startInterview(context: context)
                    } label: {
                        Label("Start Interview", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        showingLoadSheet = true
                    } label: {
                        Label("Load Campaign", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
        }
    }

    // MARK: - Bubble

    @ViewBuilder
    private func bubble(_ message: AssistantMessage) -> some View {
        let messageIndex = consultantVM.messages.firstIndex(where: { $0.id == message.id })

        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if message.role == .assistant {
                    MarkdownContentView(text: message.content.isEmpty && message.isStreaming ? "Thinking..." : message.content)
                        .textSelection(.enabled)
                        .padding(10)
                        .background(Color(.tertiarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Text(message.content)
                        .textSelection(.enabled)
                        .padding(10)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                HStack(spacing: 8) {
                    if message.isStreaming {
                        ProgressView()
                            .controlSize(.mini)
                    }

                    if let idx = messageIndex, !message.isStreaming {
                        Button {
                            editingMessageIndex = idx
                            editedMessageText = message.role == .user ? message.content : ""
                            showingForkSheet = true
                        } label: {
                            Label(
                                message.role == .user ? "Edit & Replay" : "What-If",
                                systemImage: "arrow.triangle.branch"
                            )
                            .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(.orange)
                    }
                }
            }

            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }

    // MARK: - Apply Bar

    @ViewBuilder
    private func applyBar(json: String) -> some View {
        HStack {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
            Text("Campaign ready to deploy")
                .font(.subheadline.bold())
            Spacer()
            Button {
                onApplyJSON?(json)
            } label: {
                Label("Deploy", systemImage: "banknote.fill")
                    .labelStyle(.iconOnly)
            }
            .disabled(onApplyJSON == nil)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.08))
    }

    // MARK: - Input Bar

    @ViewBuilder
    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Describe your tools, goals, or answer the consultant...", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .onSubmit { send() }

            Button {
                send()
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.title2)
            }
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || consultantVM.isStreaming)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }


    // MARK: - Actions

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""

        // send() now respects viewingStageNumber — no artificial "Let's revisit" needed
        consultantVM.send(text, context: context)

        // Auto-save if a campaign is loaded
        if consultantVM.currentCampaign != nil {
            // Delay slightly so the message appends first
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                consultantVM.autoSave(context: modelContext)
            }
        }
    }

    private func publishCampaign() async {
        guard let campaign = consultantVM.currentCampaign else { return }

        publishingCampaign = true
        defer { publishingCampaign = false }

        do {
            let oracleURL = try await MCPService().resolveOracleURL(forOperator: operatorNpub)

            // Get a token for the Oracle
            let host = oracleURL.host ?? "dpyc-oracle"
            let token: String
            if let bundle = KeychainService.loadTokenBundle(forPatron: operatorNpub, operator: host),
               !bundle.isExpired {
                token = bundle.accessToken
            } else {
                let bundle = try await OAuthService().authenticate(mcpEndpoint: oracleURL)
                try? KeychainService.saveTokenBundle(bundle, forPatron: operatorNpub, operator: host)
                token = bundle.accessToken
            }

            let result = try await MCPService().callPublishCampaign(
                oracleURL: oracleURL,
                bearerToken: token,
                authorNpub: operatorNpub,
                operatorNpub: campaign.operatorNpub,
                campaignJSON: campaign.exportJSON(),
                campaignName: campaign.name,
                campaignMarkdown: campaign.exportMarkdown()
            )

            if let data = result.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["success"] as? Bool == true {
                publishResult = "Published \"\(campaign.name)\" to DPYC community."
            } else {
                publishResult = "Publish may have failed. Check the community repo."
            }
        } catch {
            publishResult = "Publish failed: \(error.localizedDescription)"
        }

        showingPublishResult = true
    }
}

// MARK: - Campaign List Sheet

private struct CampaignListSheet: View {
    @Bindable var consultantVM: PricingConsultantViewModel
    @Binding var showingCompareSheet: Bool
    let operatorNpub: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Campaign.updatedAt, order: .reverse) private var allCampaigns: [Campaign]

    private var campaigns: [Campaign] {
        allCampaigns.filter { $0.operatorNpub == operatorNpub }
    }
    @State private var selectedForCompare: Set<PersistentIdentifier> = []
    @State private var isMultiSelectMode = false

    var body: some View {
        NavigationStack {
            Group {
                if campaigns.isEmpty {
                    ContentUnavailableView(
                        "No Saved Campaigns",
                        systemImage: "folder",
                        description: Text("Start an interview and save it to see it here.")
                    )
                } else {
                    VStack(spacing: 0) {
                        if isMultiSelectMode {
                            HStack {
                                Text("\(selectedForCompare.count) selected")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Compare Selected") {
                                    dismiss()
                                    showingCompareSheet = true
                                }
                                .disabled(selectedForCompare.count < 2)
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            Divider()
                        }

                        List {
                            ForEach(campaigns) { campaign in
                                if isMultiSelectMode {
                                    campaignSelectRow(campaign)
                                } else {
                                    Button {
                                        consultantVM.loadCampaign(campaign)
                                        dismiss()
                                    } label: {
                                        campaignRowLabel(campaign)
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            consultantVM.deleteCampaign(campaign, context: modelContext)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Saved Campaigns")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if campaigns.count >= 2 {
                    ToolbarItem(placement: .primaryAction) {
                        Button(isMultiSelectMode ? "Done" : "Compare") {
                            isMultiSelectMode.toggle()
                            if !isMultiSelectMode {
                                selectedForCompare.removeAll()
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func campaignSelectRow(_ campaign: Campaign) -> some View {
        let isSelected = selectedForCompare.contains(campaign.persistentModelID)
        Button {
            if isSelected {
                selectedForCompare.remove(campaign.persistentModelID)
            } else if selectedForCompare.count < 3 {
                selectedForCompare.insert(campaign.persistentModelID)
            }
        } label: {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                campaignRowLabel(campaign)
            }
        }
    }

    @ViewBuilder
    private func campaignRowLabel(_ campaign: Campaign) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(campaign.name)
                .font(.headline)
                .foregroundStyle(.primary)
            HStack {
                Text(campaign.operatorDisplayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(campaign.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text("\(campaign.messages.count) messages")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Interview Stepper

private struct InterviewStepperView: View {
    let progress: InterviewProgress
    var viewingStageNumber: Int?
    var isStreaming: Bool = false
    var onStageTapped: ((Int) -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { index in
                let stageNumber = index + 1
                let isCompleted = stageNumber < progress.stageNumber
                let isCurrent = stageNumber == progress.stageNumber
                let isViewing = stageNumber == viewingStageNumber
                let isTappable = isCompleted || isCurrent
                // Stage 6 turns green when recommendation is delivered (not streaming)
                let isRecommendationReady = stageNumber == 6 && isCurrent && !isStreaming

                if index > 0 {
                    Rectangle()
                        .fill(isCompleted || isRecommendationReady ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(height: 2)
                }

                VStack(spacing: 4) {
                    Button {
                        onStageTapped?(stageNumber)
                    } label: {
                        ZStack {
                            Circle()
                                .fill(chicletColor(isViewing: isViewing, isCompleted: isCompleted,
                                                   isCurrent: isCurrent, isRecommendationReady: isRecommendationReady))
                                .frame(width: 28, height: 28)

                            if (isCompleted || isRecommendationReady) && !isViewing {
                                Image(systemName: isRecommendationReady ? "star.fill" : "checkmark")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                            } else {
                                Text("\(stageNumber)")
                                    .font(.caption.bold())
                                    .foregroundStyle(isCurrent || isViewing ? .white : .secondary)
                            }
                        }
                    }
                    .disabled(!isTappable)

                    Text(InterviewProgress.stageLabels[index])
                        .font(.system(size: 9))
                        .foregroundStyle(isViewing ? .orange : (isRecommendationReady ? .green : (isCurrent ? .primary : .secondary)))
                        .lineLimit(1)
                }
            }
        }
    }

    private func chicletColor(isViewing: Bool, isCompleted: Bool, isCurrent: Bool, isRecommendationReady: Bool) -> Color {
        if isViewing { return .orange }
        if isRecommendationReady { return .green }
        if isCompleted || isCurrent { return Color.accentColor }
        return Color.secondary.opacity(0.3)
    }
}

// MARK: - Insight Summary Card

private struct InsightSummaryCard: View {
    let progress: InterviewProgress
    var projections: CampaignProjections?
    @State private var isExpanded = false

    private var hasAnyInsight: Bool {
        let i = progress.insights
        return i.toolsIdentified != nil || i.toolsCategories != nil
            || i.demandSummary != nil || i.valueSummary != nil
            || i.costSummary != nil || i.constraintsConsidered != nil
            || i.campaignDraft != nil || i.philosophy != nil
    }

    var body: some View {
        if hasAnyInsight {
            // Revenue headline (always visible, not inside disclosure)
            if let moderate = projections?.moderate {
                HStack(spacing: 12) {
                    Image(systemName: "bitcoinsign.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(moderate.revenueSats.formatted()) sats/mo")
                            .font(.caption.bold().monospacedDigit())
                        Text("$\(String(format: "%.2f", moderate.revenueUsd))/mo moderate")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let conservative = projections?.conservative,
                       let optimistic = projections?.optimistic {
                        Text("\(conservative.revenueSats.formatted())–\(optimistic.revenueSats.formatted())")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(8)
                .background(Color.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }

            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    if let tools = progress.insights.toolsIdentified {
                        insightRow("hammer", "Tools identified: \(tools)")
                    }
                    if let cats = progress.insights.toolsCategories {
                        insightRow("square.grid.2x2", "Categories: \(cats)")
                    }
                    if let demand = progress.insights.demandSummary {
                        insightRow("chart.line.uptrend.xyaxis", demand)
                    }
                    if let value = progress.insights.valueSummary {
                        insightRow("dollarsign.circle", value)
                    }
                    if let cost = progress.insights.costSummary {
                        insightRow("gauge.with.dots.needle.bottom.50percent", cost)
                    }
                    if let constraints = progress.insights.constraintsConsidered, !constraints.isEmpty {
                        insightRow("slider.horizontal.3", "Constraints: \(constraints.joined(separator: ", "))")
                    }
                    if let draft = progress.insights.campaignDraft {
                        insightRow("doc.text", "Campaign: \(draft)")
                    }
                    if let philosophy = progress.insights.philosophy {
                        insightRow("leaf.fill", "Philosophy: \(philosophy)")
                    }
                }
                .font(.caption)
                .padding(.top, 4)
            } label: {
                Label("Interview Insights — \(progress.stage.capitalized)", systemImage: "lightbulb")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func insightRow(_ icon: String, _ text: String) -> some View {
        Label {
            MarkdownContentView(text: text)
        } icon: {
            Image(systemName: icon)
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Campaign Comparison Sheet

private struct CampaignComparisonSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Campaign.updatedAt, order: .reverse) private var campaigns: [Campaign]
    @State private var selected: [Campaign] = []

    var body: some View {
        NavigationStack {
            Group {
                if selected.isEmpty {
                    campaignPicker
                } else {
                    comparisonView
                }
            }
            .navigationTitle("Compare Campaigns")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if !selected.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Pick Again") { selected = [] }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var campaignPicker: some View {
        let campaignsWithProjections = campaigns.filter { $0.revenueProjections != nil }
        if campaignsWithProjections.count < 2 {
            ContentUnavailableView(
                "Not Enough Data",
                systemImage: "chart.bar.xaxis",
                description: Text("At least 2 campaigns with revenue projections are needed. Complete the Recommendation stage to generate projections.")
            )
        } else {
            List {
                Section("Select 2-3 campaigns to compare") {
                    ForEach(campaignsWithProjections) { campaign in
                        let isSelected = selected.contains(where: { $0.persistentModelID == campaign.persistentModelID })
                        Button {
                            if isSelected {
                                selected.removeAll { $0.persistentModelID == campaign.persistentModelID }
                            } else if selected.count < 3 {
                                selected.append(campaign)
                            }
                        } label: {
                            HStack {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading) {
                                    Text(campaign.name).font(.headline)
                                    Text(campaign.updatedAt.formatted(.relative(presentation: .named)))
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }

                if selected.count >= 2 {
                    Section {
                        Button("Compare") {
                            // Trigger comparison view
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var comparisonView: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Campaign cards side by side
                HStack(alignment: .top, spacing: 12) {
                    ForEach(selected, id: \.persistentModelID) { campaign in
                        campaignCard(campaign)
                    }
                }
                .padding(.horizontal)

                // Revenue comparison
                if selected.allSatisfy({ $0.revenueProjections != nil }) {
                    revenueComparisonSection
                }
            }
            .padding(.vertical)
        }
    }

    @ViewBuilder
    private func campaignCard(_ campaign: Campaign) -> some View {
        let projections = campaign.revenueProjections
        let progress = campaign.interviewProgress

        VStack(alignment: .leading, spacing: 8) {
            Text(campaign.name)
                .font(.headline)
                .lineLimit(2)

            Text(campaign.updatedAt.formatted(.dateTime.month(.abbreviated).day()))
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if let philosophy = progress?.insights.philosophy {
                Text(philosophy.capitalized)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(philosophyColor(philosophy).opacity(0.15))
                    .clipShape(Capsule())
            }

            if let p = projections {
                if let tc = p.toolCount {
                    Label("\(tc) tools", systemImage: "hammer")
                        .font(.caption)
                }
                if let avg = p.avgPriceSats {
                    Label("\(avg) sats avg", systemImage: "dollarsign.circle")
                        .font(.caption)
                }

                Divider()

                ForEach(p.projections, id: \.scenario) { proj in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(proj.scenario.capitalized)
                            .font(.caption2.bold())
                        Text("\(proj.revenueSats.formatted()) sats/mo")
                            .font(.caption)
                        Text("$\(proj.revenueUsd, specifier: "%.2f")/mo")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var revenueComparisonSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Revenue Comparison")
                .font(.headline)
                .padding(.horizontal)

            ForEach(["conservative", "moderate", "optimistic"], id: \.self) { scenario in
                scenarioComparisonRow(scenario: scenario)
            }

            // Recommendation labels
            let bestRevenue = bestCampaign(for: "optimistic")
            let bestAdoption = bestCampaign(for: "conservative")

            if bestRevenue != nil || bestAdoption != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let best = bestRevenue {
                        Label("Best for revenue: \(best)", systemImage: "chart.line.uptrend.xyaxis")
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                    }
                    if let best = bestAdoption {
                        Label("Best for adoption: \(best)", systemImage: "person.3.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.blue)
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical)
        .background(Color(.systemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    @ViewBuilder
    private func scenarioComparisonRow(scenario: String) -> some View {
        let revenues = selected.compactMap { campaign -> (String, Int)? in
            guard let proj = campaign.revenueProjections?.projection(for: scenario) else { return nil }
            return (campaign.name, proj.revenueSats)
        }
        let maxRevenue = revenues.map(\.1).max() ?? 1

        if !revenues.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(scenario.capitalized)
                    .font(.subheadline.bold())

                ForEach(revenues, id: \.0) { name, sats in
                    let isWinner = sats == maxRevenue && revenues.count > 1
                    HStack(spacing: 8) {
                        Text(name)
                            .font(.caption)
                            .frame(width: 100, alignment: .trailing)
                            .lineLimit(1)

                        GeometryReader { geo in
                            let width = maxRevenue > 0
                                ? geo.size.width * CGFloat(sats) / CGFloat(maxRevenue)
                                : 0
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isWinner ? Color.green : Color.accentColor)
                                .frame(width: max(width, 2), height: 16)
                        }
                        .frame(height: 16)

                        Text("\(sats.formatted()) sats")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        if isWinner {
                            Image(systemName: "crown.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                        }
                    }
                }

                // Annual projection
                HStack {
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        ForEach(revenues, id: \.0) { name, sats in
                            Text("\(name): \((sats * 12).formatted()) sats/yr")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(.horizontal)

            if scenario != "optimistic" {
                Divider().padding(.horizontal)
            }
        }
    }

    private func bestCampaign(for scenario: String) -> String? {
        selected
            .compactMap { campaign -> (String, Int)? in
                guard let proj = campaign.revenueProjections?.projection(for: scenario) else { return nil }
                return (campaign.name, proj.revenueSats)
            }
            .max(by: { $0.1 < $1.1 })?
            .0
    }

    private func philosophyColor(_ philosophy: String) -> Color {
        switch philosophy.lowercased() {
        case "capitalist": return .green
        case "charitable": return .pink
        default: return .blue
        }
    }
}

// MARK: - Prompt Editor Sheet

private struct PromptEditorSheet: View {
    @Bindable var consultantVM: PricingConsultantViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    promptSourceLabel
                    Spacer()
                    if consultantVM.promptSource == .edited {
                        Button("Reset") {
                            consultantVM.resetPrompt()
                        }
                        .font(.caption)
                    }
                    Button {
                        Task { await consultantVM.loadPrompt() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()

                TextEditor(text: $consultantVM.systemPrompt)
                    .font(.system(.caption, design: .monospaced))
                    .onChange(of: consultantVM.systemPrompt) { _, _ in
                        consultantVM.markPromptEdited()
                    }
            }
            .navigationTitle("System Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var promptSourceLabel: some View {
        switch consultantVM.promptSource {
        case .community:
            Label("From dpyc-community (read-only upstream)", systemImage: "globe")
                .font(.caption)
                .foregroundStyle(.green)
        case .cached:
            Label("Cached copy (offline)", systemImage: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        case .edited:
            Label("Locally edited (session only)", systemImage: "pencil.circle")
                .font(.caption)
                .foregroundStyle(.blue)
        case .fallback:
            Label("Built-in default (fetch failed)", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.yellow)
        case .notLoaded:
            Label("Loading...", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Reshape Preview Sheet

/// Shows the AI's proposed stage assignments side-by-side with message previews.
/// The user can accept (overwrite saved campaign) or discard.
struct ReshapePreviewSheet: View {
    let messages: [AssistantMessage]
    let stages: [Int]
    var onAccept: () -> Void
    var onDiscard: () -> Void

    @Environment(\.dismiss) private var dismiss

    private let stageLabels = ["", "Inventory", "Demand", "Value", "Cost", "Constraints", "Recommendation"]
    private let stageIcons = ["", "hammer", "chart.bar", "dollarsign.circle",
                              "gauge.with.dots.needle.bottom.50percent",
                              "slider.horizontal.3", "star.fill"]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                            .font(.title2)
                            .foregroundStyle(.purple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AI Stage Classification")
                                .font(.headline)
                            Text("Review the proposed stage assignments below. Accept to overwrite the saved campaign.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                ForEach(Array(zip(messages.indices, messages)), id: \.0) { index, message in
                    let stage = index < stages.count ? stages[index] : 1
                    let oldStage = message.stageNumber ?? 0
                    let changed = oldStage != stage

                    HStack(alignment: .top, spacing: 10) {
                        // Stage badge
                        VStack(spacing: 2) {
                            Image(systemName: stageIcons[stage])
                                .font(.caption)
                                .foregroundStyle(changed ? .orange : Color.accentColor)
                            Text(stageLabels[stage])
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(changed ? .orange : .secondary)
                        }
                        .frame(width: 56)

                        // Message preview
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.role == .user ? "Operator" : "Consultant")
                                .font(.caption2.bold())
                                .foregroundStyle(message.role == .user ? Color.blue : Color.green)
                            Text(message.content.prefix(120) + (message.content.count > 120 ? "..." : ""))
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .lineLimit(3)
                                .textSelection(.enabled)
                        }

                        Spacer()

                        // Change indicator
                        if changed {
                            Image(systemName: "arrow.right.circle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Reshape Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard") {
                        dismiss()
                        onDiscard()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Accept & Save") {
                        dismiss()
                        onAccept()
                    }
                    .bold()
                }
            }
        }
    }
}
