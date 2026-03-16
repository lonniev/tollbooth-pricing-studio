import SwiftUI

/// Full-screen presentation of the pricing interview with stage-by-stage navigation.
///
/// Shows a unified view: BLUF summary → stage-by-stage transcript → model detail,
/// with a sidebar for quick navigation between interview phases.
struct FullScreenInterviewView: View {
    @Bindable var consultantVM: PricingConsultantViewModel
    let context: ConsultantContext
    let operatorNpub: String
    var onApplyJSON: ((String) -> Void)?
    var onDismiss: () -> Void

    @State private var selectedStage: Int? = nil

    private var stageGroups: [StageGroup] {
        groupMessagesByStage(consultantVM.messages)
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                // Stage sidebar
                stageSidebar
                    .frame(width: 200)

                Divider()

                // Main content
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if selectedStage == nil {
                            overviewContent
                        } else if let stage = selectedStage {
                            stageContent(stage)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle(consultantVM.currentCampaign?.name ?? "Interview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onDismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let json = consultantVM.extractedPipelineJSON {
                        Button {
                            onApplyJSON?(json)
                            onDismiss()
                        } label: {
                            Label("Apply Model", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }
                }
            }
        }
    }

    // MARK: - Stage Sidebar

    @ViewBuilder
    private var stageSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                selectedStage = nil
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .frame(width: 20)
                    Text("Overview")
                        .font(.subheadline.bold())
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(selectedStage == nil ? Color.accentColor.opacity(0.12) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)

            Divider()
                .padding(.vertical, 8)

            ForEach(0..<6, id: \.self) { index in
                let stageNumber = index + 1
                let label = InterviewProgress.stageLabels[index]
                let isReached = stageNumber <= consultantVM.interviewProgress.stageNumber
                let hasMessages = stageGroups.contains(where: { $0.stage == stageNumber })

                Button {
                    selectedStage = stageNumber
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: stageIcon(stageNumber))
                            .frame(width: 20)
                            .foregroundStyle(isReached ? Color.accentColor : Color.secondary.opacity(0.3))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(label)
                                .font(.subheadline)
                                .foregroundStyle(isReached ? .primary : .tertiary)

                            if hasMessages {
                                let count = stageGroups.first(where: { $0.stage == stageNumber })?.messages.count ?? 0
                                Text("\(count) messages")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        Spacer()

                        if stageNumber < consultantVM.interviewProgress.stageNumber {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else if stageNumber == consultantVM.interviewProgress.stageNumber {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 8, height: 8)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(selectedStage == stageNumber ? Color.accentColor.opacity(0.12) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(!isReached)
                .padding(.horizontal, 8)
            }

            Spacer()

            // Insights summary at bottom of sidebar
            if let philosophy = consultantVM.interviewProgress.insights.philosophy {
                VStack(alignment: .leading, spacing: 4) {
                    Divider()
                    Label(philosophy.capitalized, systemImage: philosophyIcon(philosophy))
                        .font(.caption)
                        .foregroundStyle(philosophyColor(philosophy))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }
        }
        .padding(.vertical, 8)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Overview Content

    @ViewBuilder
    private var overviewContent: some View {
        // BLUF section
        if consultantVM.interviewProgress.stageNumber >= 6 {
            blufSection
        }

        // Revenue projections
        if let projections = consultantVM.revenueProjections {
            revenueSection(projections)
        }

        // Stage progress overview
        stageProgressOverview

        // Pipeline JSON preview
        if let json = consultantVM.extractedPipelineJSON {
            pipelinePreview(json)
        }
    }

    @ViewBuilder
    private var blufSection: some View {
        let insights = consultantVM.interviewProgress.insights

        VStack(alignment: .leading, spacing: 12) {
            Label("Bottom Line Up Front", systemImage: "star.fill")
                .font(.title3.bold())

            VStack(alignment: .leading, spacing: 8) {
                if let philosophy = insights.philosophy {
                    HStack(spacing: 6) {
                        Image(systemName: philosophyIcon(philosophy))
                            .foregroundStyle(philosophyColor(philosophy))
                        Text("Recommended approach: **\(philosophy.capitalized)**")
                    }
                }
                if let demand = insights.demandSummary {
                    Text("Demand: \(demand)")
                }
                if let value = insights.valueSummary {
                    Text("Value: \(value)")
                }
                if let cost = insights.costSummary {
                    Text("Cost: \(cost)")
                }
                if let constraints = insights.constraintsConsidered, !constraints.isEmpty {
                    Text("Key constraints: \(constraints.joined(separator: ", "))")
                }
                if let draft = insights.campaignDraft {
                    Label("Campaign status: \(draft)", systemImage: draft == "approved" ? "checkmark.seal.fill" : "doc.text")
                        .foregroundStyle(draft == "approved" ? .green : .secondary)
                }
            }
            .font(.subheadline)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private func revenueSection(_ projections: CampaignProjections) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Revenue Projections", systemImage: "chart.bar.fill")
                .font(.title3.bold())

            // Revenue table
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(spacing: 0) {
                    Text("Scenario").font(.caption.bold()).frame(width: 100, alignment: .leading)
                    Text("Users/Mo").font(.caption.bold()).frame(width: 80, alignment: .trailing)
                    Text("Calls/User").font(.caption.bold()).frame(width: 80, alignment: .trailing)
                    Text("Sats/Mo").font(.caption.bold()).frame(width: 100, alignment: .trailing)
                    Text("USD/Mo").font(.caption.bold()).frame(width: 80, alignment: .trailing)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

                Divider()

                ForEach(projections.projections, id: \.scenario) { proj in
                    HStack(spacing: 0) {
                        Text(proj.scenario.capitalized).font(.caption).frame(width: 100, alignment: .leading)
                        Text("\(proj.monthlyUsers)").font(.caption.monospacedDigit()).frame(width: 80, alignment: .trailing)
                        Text("\(proj.callsPerUserPerMonth)").font(.caption.monospacedDigit()).frame(width: 80, alignment: .trailing)
                        Text("\(proj.revenueSats.formatted())").font(.caption.monospacedDigit()).frame(width: 100, alignment: .trailing)
                        Text("$\(proj.revenueUsd, specifier: "%.2f")").font(.caption.monospacedDigit()).frame(width: 80, alignment: .trailing)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))

            // TAM/SAM/SOM
            if projections.tam != nil || projections.sam != nil || projections.som != nil {
                HStack(spacing: 16) {
                    if let tam = projections.tam {
                        Label("TAM: \(tam)", systemImage: "globe").font(.caption2)
                    }
                    if let sam = projections.sam {
                        Label("SAM: \(sam)", systemImage: "person.3").font(.caption2)
                    }
                    if let som = projections.som {
                        Label("SOM: \(som)", systemImage: "target").font(.caption2)
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var stageProgressOverview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Interview Progress", systemImage: "list.number")
                .font(.title3.bold())

            ForEach(0..<6, id: \.self) { index in
                let stageNumber = index + 1
                let label = InterviewProgress.stageLabels[index]
                let isReached = stageNumber <= consultantVM.interviewProgress.stageNumber
                let messageCount = stageGroups.first(where: { $0.stage == stageNumber })?.messages.count ?? 0

                HStack(spacing: 12) {
                    Image(systemName: stageIcon(stageNumber))
                        .frame(width: 20)
                        .foregroundStyle(isReached ? Color.accentColor : Color.secondary.opacity(0.3))

                    Text(label)
                        .font(.subheadline)
                        .foregroundStyle(isReached ? .primary : .tertiary)

                    Spacer()

                    if messageCount > 0 {
                        Button {
                            selectedStage = stageNumber
                        } label: {
                            Text("\(messageCount) messages")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }

                    if stageNumber < consultantVM.interviewProgress.stageNumber {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if stageNumber == consultantVM.interviewProgress.stageNumber {
                        Image(systemName: "circle.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Image(systemName: "circle")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func pipelinePreview(_ json: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Approved Pipeline", systemImage: "checkmark.seal.fill")
                .font(.title3.bold())
                .foregroundStyle(.green)

            Text(json)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Stage Content

    @ViewBuilder
    private func stageContent(_ stage: Int) -> some View {
        let label = stage <= InterviewProgress.stageLabels.count
            ? InterviewProgress.stageLabels[stage - 1]
            : "Stage \(stage)"

        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: stageIcon(stage))
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading) {
                    Text("Phase \(stage): \(label)")
                        .font(.title2.bold())
                    Text(stageDescription(stage))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            if let group = stageGroups.first(where: { $0.stage == stage }) {
                ForEach(group.messages) { message in
                    messageBubble(message)
                }
            } else {
                ContentUnavailableView(
                    "Not Yet Reached",
                    systemImage: "clock",
                    description: Text("This phase hasn't been started yet.")
                )
            }
        }
    }

    @ViewBuilder
    private func messageBubble(_ message: AssistantMessage) -> some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: message.role == .user ? "person.fill" : "brain.head.profile")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(message.role == .user ? "Operator" : "Consultant")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(message.timestamp.formatted(.dateTime.hour().minute()))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if message.role == .assistant {
                    MarkdownContentView(text: message.content.isEmpty && message.isStreaming ? "Thinking..." : message.content)
                        .textSelection(.enabled)
                        .padding(12)
                        .background(Color(.tertiarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Text(message.content)
                        .textSelection(.enabled)
                        .padding(12)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                if message.isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }

    // MARK: - Helpers

    private func groupMessagesByStage(_ messages: [AssistantMessage]) -> [StageGroup] {
        var groups: [StageGroup] = []
        var currentStage = 0
        var currentMessages: [AssistantMessage] = []

        for message in messages {
            let stage = message.stageNumber ?? currentStage
            if stage != currentStage && !currentMessages.isEmpty {
                groups.append(StageGroup(stage: currentStage, messages: currentMessages))
                currentMessages = []
            }
            currentStage = stage
            currentMessages.append(message)
        }
        if !currentMessages.isEmpty {
            groups.append(StageGroup(stage: currentStage, messages: currentMessages))
        }
        return groups
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

    private func stageDescription(_ stage: Int) -> String {
        switch stage {
        case 1: return "Discovering your tools, categories, and current pricing"
        case 2: return "Exploring expected usage patterns and market size"
        case 3: return "Assessing willingness-to-pay and competitive positioning"
        case 4: return "Understanding serving costs and margin requirements"
        case 5: return "Designing promotional mechanics and constraint rules"
        case 6: return "Presenting the complete pricing campaign recommendation"
        default: return ""
        }
    }

    private func philosophyIcon(_ philosophy: String) -> String {
        switch philosophy.lowercased() {
        case "capitalist": return "chart.line.uptrend.xyaxis"
        case "charitable": return "heart.fill"
        default: return "scale.3d"
        }
    }

    private func philosophyColor(_ philosophy: String) -> Color {
        switch philosophy.lowercased() {
        case "capitalist": return .green
        case "charitable": return .pink
        default: return .blue
        }
    }

    private struct StageGroup {
        let stage: Int
        let messages: [AssistantMessage]
    }
}
