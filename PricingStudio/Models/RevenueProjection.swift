import Foundation

/// A single revenue scenario projection.
struct RevenueProjection: Codable, Equatable {
    var scenario: String
    var monthlyUsers: Int
    var callsPerUserPerMonth: Int
    var revenueSats: Int
    var revenueUsd: Double

    /// Monthly revenue formatted as sats string.
    var formattedSats: String {
        "\(revenueSats.formatted()) sats/mo"
    }

    /// Annual revenue in sats.
    var annualSats: Int {
        revenueSats * 12
    }

    /// Annual revenue in USD.
    var annualUsd: Double {
        revenueUsd * 12
    }
}

/// Campaign-level projections container.
struct CampaignProjections: Codable, Equatable {
    var projections: [RevenueProjection]
    var tam: String?
    var sam: String?
    var som: String?
    var toolCount: Int?
    var avgPriceSats: Int?

    /// Find projection by scenario name.
    func projection(for scenario: String) -> RevenueProjection? {
        projections.first { $0.scenario.lowercased() == scenario.lowercased() }
    }

    /// Convenience accessors for the three standard scenarios.
    var conservative: RevenueProjection? { projection(for: "conservative") }
    var moderate: RevenueProjection? { projection(for: "moderate") }
    var optimistic: RevenueProjection? { projection(for: "optimistic") }
}
