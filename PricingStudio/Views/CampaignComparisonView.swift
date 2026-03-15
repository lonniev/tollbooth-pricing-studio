import SwiftUI
import SwiftData

/// Standalone comparison view for up to 3 campaigns.
///
/// Shows side-by-side campaign cards with revenue projections and
/// bar chart comparisons. All math is local — no Claude needed.
struct CampaignComparisonView: View {
    let campaigns: [Campaign]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Campaign cards
                HStack(alignment: .top, spacing: 12) {
                    ForEach(campaigns, id: \.persistentModelID) { campaign in
                        campaignCard(campaign)
                    }
                }

                // Revenue comparison bars
                if campaigns.allSatisfy({ $0.revenueProjections != nil }) {
                    revenueSection
                }
            }
            .padding()
        }
    }

    // MARK: - Campaign Card

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
                        Text(proj.formattedSats)
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

    // MARK: - Revenue Comparison

    @ViewBuilder
    private var revenueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Revenue Comparison")
                .font(.headline)

            ForEach(["conservative", "moderate", "optimistic"], id: \.self) { scenario in
                scenarioBar(scenario)
            }

            // Recommendation
            recommendationLabels
        }
        .padding()
        .background(Color(.systemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func scenarioBar(_ scenario: String) -> some View {
        let revenues = campaigns.compactMap { campaign -> (String, Int)? in
            guard let proj = campaign.revenueProjections?.projection(for: scenario) else { return nil }
            return (campaign.name, proj.revenueSats)
        }
        let maxRevenue = revenues.map(\.1).max() ?? 1

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

            // Annual
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
    }

    @ViewBuilder
    private var recommendationLabels: some View {
        let bestRevenue = bestCampaign(for: "optimistic")
        let bestAdoption = bestCampaign(for: "conservative")

        if bestRevenue != nil || bestAdoption != nil {
            Divider()
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
        }
    }

    // MARK: - Helpers

    private func bestCampaign(for scenario: String) -> String? {
        campaigns
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
