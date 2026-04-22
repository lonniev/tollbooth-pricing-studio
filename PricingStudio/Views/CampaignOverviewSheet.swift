import SwiftUI

/// Read-only infographic summary of a saved campaign.
///
/// Shows BLUF metrics, revenue projections, constraint pipeline timeline,
/// price table, and peer review verdict — everything an operator needs to
/// evaluate a campaign at a glance without opening the full interview.
struct CampaignOverviewSheet: View {
    let campaign: Campaign
    var onDismiss: () -> Void

    @State private var panelOffset: CGSize = .zero
    @State private var panelSize: CGSize = CGSize(width: 520, height: 640)
    @GestureState private var dragOffset: CGSize = .zero
    @GestureState private var resizeDelta: CGSize = .zero

    private let minSize = CGSize(width: 360, height: 400)
    private let maxSize = CGSize(width: 900, height: 1100)

    private var progress: InterviewProgress? { campaign.interviewProgress }
    private var projections: CampaignProjections? {
        campaign.proposal?.projections ?? campaign.revenueProjections
    }
    private var proposal: PricingProposal? { campaign.proposal }
    private var review: PeerReview? { campaign.peerReview }
    private var insights: InterviewProgress.Insights? { progress?.insights }

    private var currentWidth: CGFloat {
        min(max(panelSize.width + resizeDelta.width, minSize.width), maxSize.width)
    }
    private var currentHeight: CGFloat {
        min(max(panelSize.height + resizeDelta.height, minSize.height), maxSize.height)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle / title bar
            HStack {
                Text(campaign.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button { onDismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemGroupedBackground))
            .gesture(
                DragGesture()
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        panelOffset.width += value.translation.width
                        panelOffset.height += value.translation.height
                    }
            )

            Divider()

            // Scrollable content
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    headerSection
                    blufSection
                    revenueSection
                    priceTableSection
                    pipelineSection
                    reviewSection
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))

            // Resize handle
            HStack {
                Spacer()
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(6)
                    .gesture(
                        DragGesture()
                            .updating($resizeDelta) { value, state, _ in
                                state = value.translation
                            }
                            .onEnded { value in
                                panelSize.width = min(max(panelSize.width + value.translation.width, minSize.width), maxSize.width)
                                panelSize.height = min(max(panelSize.height + value.translation.height, minSize.height), maxSize.height)
                            }
                    )
            }
            .background(Color(.secondarySystemGroupedBackground))
        }
        .frame(width: currentWidth, height: currentHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
        .offset(
            x: panelOffset.width + dragOffset.width,
            y: panelOffset.height + dragOffset.height
        )
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(campaign.operatorDisplayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if campaign.isDeployed {
                        Label("LIVE", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(.green, in: Capsule())
                    }
                    if let stage = progress {
                        let label = stage.stageNumber <= InterviewProgress.stageLabels.count
                            ? InterviewProgress.stageLabels[stage.stageNumber - 1]
                            : "Stage \(stage.stageNumber)"
                        Text("Stage \(stage.stageNumber)/6: \(label)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Text(campaign.updatedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - BLUF

    @ViewBuilder
    private var blufSection: some View {
        if let insights, (progress?.stageNumber ?? 0) >= 5 {
            VStack(alignment: .leading, spacing: 12) {
                Label("Bottom Line Up Front", systemImage: "star.fill")
                    .font(.title3.bold())

                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                ], spacing: 12) {
                    // Revenue headline
                    if let moderate = projections?.moderate {
                        metricCard(
                            icon: "bitcoinsign.circle.fill",
                            value: "\(moderate.revenueSats.formatted())",
                            unit: "sats/mo",
                            subtitle: "$\(String(format: "%.2f", moderate.revenueUsd))/mo",
                            color: .green
                        )
                    }

                    // Philosophy
                    if let philosophy = insights.philosophy {
                        metricCard(
                            icon: philosophyIcon(philosophy),
                            value: philosophy.capitalized,
                            unit: "approach",
                            subtitle: nil,
                            color: philosophyColor(philosophy)
                        )
                    }

                    // Tool count
                    if let tc = projections?.toolCount {
                        metricCard(
                            icon: "hammer.fill",
                            value: "\(tc)",
                            unit: "tools",
                            subtitle: projections?.avgPriceSats.map { "\($0) sats avg" },
                            color: .blue
                        )
                    }

                    // Campaign status
                    if let draft = insights.campaignDraft {
                        metricCard(
                            icon: draft == "approved" ? "checkmark.seal.fill" : "doc.text",
                            value: draft.capitalized,
                            unit: "status",
                            subtitle: nil,
                            color: draft == "approved" ? .green : .secondary
                        )
                    }

                    // Constraints
                    if let constraints = insights.constraintsConsidered, !constraints.isEmpty {
                        metricCard(
                            icon: "slider.horizontal.3",
                            value: "\(constraints.count)",
                            unit: constraints.count == 1 ? "constraint" : "constraints",
                            subtitle: constraints.first,
                            color: .orange
                        )
                    }

                    // Review verdict
                    if let review {
                        metricCard(
                            icon: verdictIcon(review.verdict),
                            value: verdictLabel(review.verdict),
                            unit: review.providerName,
                            subtitle: nil,
                            color: verdictColor(review.verdict)
                        )
                    }
                }

                // Revenue range bar
                if let conservative = projections?.conservative,
                   let optimistic = projections?.optimistic {
                    revenueRangeBar(conservative: conservative, optimistic: optimistic)
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Revenue Projections

    @ViewBuilder
    private var revenueSection: some View {
        if let projections, !projections.projections.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label("Revenue Projections", systemImage: "chart.bar.fill")
                    .font(.title3.bold())

                VStack(alignment: .leading, spacing: 0) {
                    // Header row
                    HStack(spacing: 0) {
                        Text("Scenario").font(.caption.bold()).frame(maxWidth: .infinity, alignment: .leading)
                        Text("Users/Mo").font(.caption.bold()).frame(maxWidth: .infinity, alignment: .trailing)
                        Text("Calls/User").font(.caption.bold()).frame(maxWidth: .infinity, alignment: .trailing)
                        Text("Sats/Mo").font(.caption.bold()).frame(maxWidth: .infinity, alignment: .trailing)
                        Text("USD/Mo").font(.caption.bold()).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)

                    Divider()

                    ForEach(projections.projections, id: \.scenario) { proj in
                        HStack(spacing: 0) {
                            Text(proj.scenario.capitalized)
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(proj.monthlyUsers)")
                                .font(.caption.monospacedDigit())
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text("\(proj.callsPerUserPerMonth)")
                                .font(.caption.monospacedDigit())
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text("\(proj.revenueSats.formatted())")
                                .font(.caption.monospacedDigit())
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text("$\(proj.revenueUsd, specifier: "%.2f")")
                                .font(.caption.monospacedDigit())
                                .frame(maxWidth: .infinity, alignment: .trailing)
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
            .padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Price Table

    @ViewBuilder
    private var priceTableSection: some View {
        if let toolPrices = proposal?.toolPrices, !toolPrices.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label("Tool Prices", systemImage: "tablecells")
                    .font(.title3.bold())

                VStack(alignment: .leading, spacing: 0) {
                    // Header
                    HStack(spacing: 0) {
                        Text("Tool").font(.caption.bold()).frame(maxWidth: .infinity, alignment: .leading)
                        Text("Category").font(.caption.bold()).frame(maxWidth: .infinity, alignment: .leading)
                        Text("Price").font(.caption.bold()).frame(maxWidth: .infinity, alignment: .trailing)
                        Text("Type").font(.caption.bold()).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)

                    Divider()

                    ForEach(toolPrices) { tool in
                        HStack(spacing: 0) {
                            Text(tool.toolName)
                                .font(.caption)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(tool.category)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(tool.priceSats) sats")
                                .font(.caption.monospacedDigit())
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text(tool.priceType.rawValue)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Constraint Pipeline

    @ViewBuilder
    private var pipelineSection: some View {
        if let pipeline = proposal?.pipeline, !pipeline.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label("Constraint Pipeline", systemImage: "arrow.triangle.branch")
                    .font(.title3.bold())

                ForEach(Array(pipeline.enumerated()), id: \.element.id) { index, step in
                    HStack(alignment: .top, spacing: 12) {
                        // Timeline connector
                        VStack(spacing: 0) {
                            Circle()
                                .fill(constraintColor(step.type))
                                .frame(width: 10, height: 10)
                            if index < pipeline.count - 1 {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.3))
                                    .frame(width: 2)
                                    .frame(minHeight: 30)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.type.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.subheadline.bold())

                            // Show key params
                            let paramSummary = step.params.map { "\($0.key): \($0.value)" }
                                .joined(separator: " · ")
                            if !paramSummary.isEmpty {
                                Text(paramSummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }

                        Spacer()
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Peer Review

    @ViewBuilder
    private var reviewSection: some View {
        if let review {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Peer Review", systemImage: "person.2.fill")
                        .font(.title3.bold())
                    Spacer()
                    Text(review.providerName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let verdict = review.verdict {
                        Text(verdictLabel(verdict))
                            .font(.caption.bold())
                            .foregroundStyle(verdictColor(verdict))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(verdictColor(verdict).opacity(0.12), in: Capsule())
                    }
                }

                ForEach(review.sections) { section in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(section.title, systemImage: section.icon)
                            .font(.subheadline.bold())
                        Text(section.content)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Components

    @ViewBuilder
    private func metricCard(icon: String, value: String, unit: String, subtitle: String?, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func revenueRangeBar(conservative: RevenueProjection, optimistic: RevenueProjection) -> some View {
        HStack(spacing: 8) {
            Text("\(conservative.revenueSats.formatted())")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            GeometryReader { geo in
                let moderateRatio = projections?.moderate.map {
                    CGFloat($0.revenueSats - conservative.revenueSats) /
                    CGFloat(max(optimistic.revenueSats - conservative.revenueSats, 1))
                } ?? 0.5

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.blue, .green, .orange],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 8)

                    Circle()
                        .fill(.white)
                        .frame(width: 12, height: 12)
                        .shadow(radius: 1)
                        .offset(x: geo.size.width * moderateRatio - 6)
                }
            }
            .frame(height: 12)

            Text("\(optimistic.revenueSats.formatted())")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            Text("sats/mo")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Helpers

    private func constraintColor(_ type: String) -> Color {
        switch type {
        case "temporal_window": return .orange
        case "finite_supply": return .red
        case "periodic_refresh": return .blue
        case "coupon": return .purple
        case "free_trial": return .green
        case "loyalty_discount": return .pink
        case "bulk_bonus": return .cyan
        case "happy_hour": return .yellow
        default: return .secondary
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

    private func verdictIcon(_ verdict: ReviewVerdict?) -> String {
        switch verdict {
        case .approve: return "checkmark.seal.fill"
        case .approveWithReservations: return "checkmark.circle.badge.questionmark"
        case .reworkRecommended: return "arrow.triangle.2.circlepath"
        case .reject: return "xmark.seal.fill"
        case nil: return "questionmark.circle"
        }
    }

    private func verdictLabel(_ verdict: ReviewVerdict?) -> String {
        switch verdict {
        case .approve: return "Approved"
        case .approveWithReservations: return "With Reservations"
        case .reworkRecommended: return "Rework"
        case .reject: return "Rejected"
        case nil: return "Pending"
        }
    }

    private func verdictColor(_ verdict: ReviewVerdict?) -> Color {
        switch verdict {
        case .approve: return .green
        case .approveWithReservations: return .orange
        case .reworkRecommended: return .yellow
        case .reject: return .red
        case nil: return .secondary
        }
    }
}
