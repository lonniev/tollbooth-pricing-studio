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

    @Environment(\.modelContext) private var modelContext
    @State private var inputText = ""
    @State private var showingAPIKeySheet = false
    @State private var showingPromptEditor = false
    @State private var showingSaveSheet = false
    @State private var showingLoadSheet = false
    @State private var showingCompareSheet = false
    @State private var saveName = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if !consultantVM.messages.isEmpty {
                InterviewStepperView(
                    progress: consultantVM.interviewProgress,
                    viewingStageNumber: consultantVM.viewingStageNumber,
                    onStageTapped: { stage in
                        consultantVM.revisitStage(stage)
                    }
                )
                .padding(.horizontal)
                .padding(.vertical, 8)

                InsightSummaryCard(progress: consultantVM.interviewProgress)
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
        .sheet(isPresented: $showingPromptEditor) {
            PromptEditorSheet(consultantVM: consultantVM)
        }
        .sheet(isPresented: $showingLoadSheet) {
            CampaignListSheet(consultantVM: consultantVM, showingCompareSheet: $showingCompareSheet)
        }
        .sheet(isPresented: $showingCompareSheet) {
            CampaignComparisonSheet()
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

            // Export
            if !consultantVM.messages.isEmpty {
                ShareLink(
                    item: consultantVM.exportTranscript(),
                    subject: Text("Pricing Interview"),
                    message: Text("Interview transcript from Pricing Studio")
                ) {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .labelStyle(.iconOnly)
                }
            }

            // Campaign actions
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
                Label("Save", systemImage: "square.and.arrow.down")
                    .labelStyle(.iconOnly)
            }
            .disabled(consultantVM.messages.isEmpty)

            Button {
                showingPromptEditor = true
            } label: {
                Label("Edit Prompt", systemImage: "doc.text")
                    .labelStyle(.iconOnly)
            }

            Button {
                consultantVM.clear()
            } label: {
                Label("Clear", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .disabled(consultantVM.messages.isEmpty)

            Button {
                showingAPIKeySheet = true
            } label: {
                Label("API Key", systemImage: "key")
                    .labelStyle(.iconOnly)
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
                    if consultantVM.messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(consultantVM.displayedMessages) { message in
                            bubble(message)
                                .id(message.id)
                        }
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
                    Label("Synthesis — draft + refine", systemImage: "6.circle")
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

                if message.isStreaming {
                    ProgressView()
                        .controlSize(.mini)
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
            Text("Pipeline ready to apply")
                .font(.subheadline.bold())
            Spacer()
            Button {
                onApplyJSON?(json)
            } label: {
                Label("Apply Model", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
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

        // If viewing a past stage, prepend a revisit message
        if let viewing = consultantVM.viewingStageNumber,
           viewing != consultantVM.interviewProgress.stageNumber {
            let stageName = viewing <= InterviewProgress.stageLabels.count
                ? InterviewProgress.stageLabels[viewing - 1]
                : "Stage \(viewing)"
            let revisitMsg = AssistantMessage(
                role: .user,
                content: "Let's revisit \(stageName).",
                stageNumber: viewing
            )
            consultantVM.messages.append(revisitMsg)
        }

        consultantVM.send(text, context: context)

        // Auto-save if a campaign is loaded
        if consultantVM.currentCampaign != nil {
            // Delay slightly so the message appends first
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                consultantVM.autoSave(context: modelContext)
            }
        }
    }
}

// MARK: - Campaign List Sheet

private struct CampaignListSheet: View {
    @Bindable var consultantVM: PricingConsultantViewModel
    @Binding var showingCompareSheet: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Campaign.updatedAt, order: .reverse) private var campaigns: [Campaign]
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
    var onStageTapped: ((Int) -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { index in
                let stageNumber = index + 1
                let isCompleted = stageNumber < progress.stageNumber
                let isCurrent = stageNumber == progress.stageNumber
                let isViewing = stageNumber == viewingStageNumber
                let isTappable = isCompleted || isCurrent

                if index > 0 {
                    Rectangle()
                        .fill(isCompleted ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(height: 2)
                }

                VStack(spacing: 4) {
                    Button {
                        onStageTapped?(stageNumber)
                    } label: {
                        ZStack {
                            Circle()
                                .fill(isViewing ? Color.orange : (isCompleted || isCurrent ? Color.accentColor : Color.secondary.opacity(0.3)))
                                .frame(width: 28, height: 28)

                            if isCompleted && !isViewing {
                                Image(systemName: "checkmark")
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
                        .foregroundStyle(isViewing ? .orange : (isCurrent ? .primary : .secondary))
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Insight Summary Card

private struct InsightSummaryCard: View {
    let progress: InterviewProgress
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
                description: Text("At least 2 campaigns with revenue projections are needed. Complete the Synthesis stage to generate projections.")
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
