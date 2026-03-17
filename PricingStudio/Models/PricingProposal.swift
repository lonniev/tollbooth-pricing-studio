import Foundation

/// The math-friendly pricing proposal extracted from a completed interview.
///
/// Contains the constraint pipeline, per-tool sat prices, and revenue
/// projections — no conversation text, just numbers. This is the slice
/// you hand to a reviewer or deploy to the tollbooth.
struct PricingProposal: Codable {
    /// Raw constraint pipeline JSON as emitted by the consultant.
    var pipelineJSON: String?

    /// Decoded pipeline steps, if pipeline JSON was valid.
    var pipeline: [PipelineStep]?

    /// Per-tool sat prices from the recommendation.
    var toolPrices: [ToolPrice]?

    /// TAM/SAM/SOM and 3-scenario revenue projections.
    var projections: CampaignProjections?

    /// When the consultant generated this proposal.
    var generatedAt: Date?

    init(
        pipelineJSON: String? = nil,
        pipeline: [PipelineStep]? = nil,
        toolPrices: [ToolPrice]? = nil,
        projections: CampaignProjections? = nil,
        generatedAt: Date? = nil
    ) {
        self.pipelineJSON = pipelineJSON
        self.pipeline = pipeline
        self.toolPrices = toolPrices
        self.projections = projections
        self.generatedAt = generatedAt
    }
}
