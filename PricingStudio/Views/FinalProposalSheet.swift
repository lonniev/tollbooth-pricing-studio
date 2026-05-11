import SwiftUI

/// Standalone presentation of the team's consolidated PricingProposal.
///
/// Distinct from Hayek's chat room: this is a document/dashboard view of the
/// proposal as the team's product, not Hayek's monologue. Hayek does the
/// synthesis work via merge_proposal; this sheet shows the result.
struct FinalProposalSheet: View {
    let campaign: Campaign?
    /// Triggered when the user wants Hayek to (re)synthesize. Caller closes
    /// the sheet and routes the user into Hayek's chat with a primed turn.
    var onRefreshSynthesis: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    teamBanner

                    if let proposal = campaign?.proposal {
                        generatedStamp(proposal)
                        if let bluf = blufSummary(from: proposal) {
                            section("Bottom Line", content: bluf)
                        }
                        if let prices = proposal.toolPrices, !prices.isEmpty {
                            toolPricesSection(prices)
                        }
                        if let pipeline = proposal.pipeline, !pipeline.isEmpty {
                            pipelineSection(pipeline)
                        }
                        if let projections = proposal.projections {
                            projectionsSection(projections)
                        }
                    } else {
                        emptyState
                    }
                }
                .padding(20)
            }
            .navigationTitle("Final Proposal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onDismiss)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onRefreshSynthesis()
                    } label: {
                        Label(campaign?.proposal == nil ? "Ask Hayek to Synthesize" : "Refresh with Hayek",
                              systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }
        }
    }

    // MARK: - Banner

    private var teamBanner: some View {
        VStack(spacing: 12) {
            TeamPortraitCollage(diameter: 52, overlap: 18, ringColor: .white)
                .padding(.top, 8)
            Text("Brought to you by the Team")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Menger · Wieser · Böhm-Bawerk · Wicksteed · Mises · Hayek")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(
                    colors: [.indigo, .purple],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
        )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("No proposal synthesized yet")
                .font(.headline)
            Text("The team has gathered notes but Hayek hasn't merged them into a final proposal. Ask him to synthesize when you're ready.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: - Sections

    private func generatedStamp(_ proposal: PricingProposal) -> some View {
        Group {
            if let when = proposal.generatedAt {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.caption2)
                    Text("Synthesized \(when.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.bold())
                .tracking(1.2)
                .foregroundStyle(.indigo)
            content()
        }
    }

    private func section(_ title: String, content: String) -> some View {
        section(title) {
            Text(content)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func blufSummary(from proposal: PricingProposal) -> String? {
        var parts: [String] = []
        if let count = proposal.toolPrices?.count, count > 0 {
            let total = proposal.toolPrices?.reduce(0) { $0 + $1.priceSats } ?? 0
            let avg = count > 0 ? total / count : 0
            parts.append("\(count) tools priced, average \(avg) sats per call.")
        }
        if let steps = proposal.pipeline?.count, steps > 0 {
            parts.append("\(steps)-step constraint pipeline.")
        }
        if let moderate = proposal.projections?.moderate {
            let usd = String(format: "%.2f", moderate.revenueUsd)
            parts.append("Moderate-scenario revenue: \(moderate.revenueSats.formatted()) sats/mo (~$\(usd)).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func toolPricesSection(_ prices: [ToolPrice]) -> some View {
        section("Tool Prices") {
            VStack(spacing: 6) {
                ForEach(prices) { price in
                    HStack(alignment: .firstTextBaseline) {
                        Text(price.toolName)
                            .font(.callout.weight(.medium))
                        Spacer(minLength: 12)
                        Text("\(price.priceSats) sats")
                            .font(.callout.monospaced())
                            .foregroundStyle(price.priceSats == 0 ? .secondary : .primary)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 10)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func pipelineSection(_ steps: [PipelineStep]) -> some View {
        section("Constraint Pipeline") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.caption.bold())
                            .foregroundStyle(.indigo)
                        Text(step.type.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.callout.weight(.medium))
                        if step.isScoped {
                            Image(systemName: "scope")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func projectionsSection(_ projections: CampaignProjections) -> some View {
        section("Revenue Projections") {
            VStack(spacing: 6) {
                ForEach(projections.projections, id: \.scenario) { p in
                    HStack(alignment: .firstTextBaseline) {
                        Text(p.scenario.capitalized)
                            .font(.callout.weight(.medium))
                            .frame(width: 100, alignment: .leading)
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(p.revenueSats.formatted()) sats/mo")
                                .font(.callout.monospaced())
                            Text("$\(String(format: "%.2f", p.revenueUsd))/mo")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}
