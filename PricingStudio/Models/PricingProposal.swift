import Foundation

/// The math-friendly pricing proposal extracted from a completed interview.
///
/// Contains the per-tool sat prices (each ``ToolPrice.chain`` carries that
/// tool's proposed constraint chain) plus revenue projections — no
/// conversation text, just numbers. This is the slice you hand to a
/// reviewer or deploy to the tollbooth.
///
/// As of tollbooth-dpyc 0.40.0 there is no operator-wide constraint
/// pipeline: constraints live on each tool. The proposal therefore
/// carries chains implicitly through ``toolPrices``.
struct PricingProposal: Codable {
    /// Per-tool sat prices from the recommendation. Each tool's
    /// proposed constraint chain rides along on ``ToolPrice.chain``.
    var toolPrices: [ToolPrice]?

    /// TAM/SAM/SOM and 3-scenario revenue projections.
    var projections: CampaignProjections?

    /// When the consultant generated this proposal.
    var generatedAt: Date?

    init(
        toolPrices: [ToolPrice]? = nil,
        projections: CampaignProjections? = nil,
        generatedAt: Date? = nil
    ) {
        self.toolPrices = toolPrices
        self.projections = projections
        self.generatedAt = generatedAt
    }

    /// Total number of chain steps across all tools — useful for
    /// surfacing "N constraints proposed" in summaries without
    /// rebuilding the count per call site.
    var totalChainSteps: Int {
        toolPrices?.reduce(0) { $0 + $1.chain.count } ?? 0
    }

    /// Tools that carry at least one chain step — for "which tools
    /// have proposed constraints" headers.
    var toolsWithChains: [ToolPrice] {
        (toolPrices ?? []).filter { !$0.chain.isEmpty }
    }
}
