import Foundation

/// Stateless service for building focused text summaries of campaign data
/// for LLM consumption.
///
/// Each builder method produces a string optimized for a specific LLM task
/// (review, reshape, revision) — including only the context that task needs.
enum CampaignSummaryBuilder {

    // MARK: - Second Opinion Summary

    /// Build a single-message summary of the campaign for a reviewer LLM.
    static func buildForSecondOpinion(
        messages: [AssistantMessage],
        progress: InterviewProgress,
        projections: CampaignProjections?,
        pipelineJSON: String?,
        operatorName: String?,
        campaignName: String?
    ) -> String {
        var parts: [String] = []

        // Identity
        let name = campaignName ?? "Untitled Campaign"
        let opName = operatorName ?? "Unknown Operator"
        parts.append("## Campaign: \(name)")
        parts.append("Operator: \(opName)")

        // Interview insights
        let insights = progress.insights
        parts.append("\n## Interview Insights")
        parts.append("Stage reached: \(progress.stage) (\(progress.stageNumber)/6)")
        if let tools = insights.toolsIdentified {
            parts.append("Tools identified: \(tools)")
        }
        if let cats = insights.toolsCategories {
            parts.append("Tool categories: \(cats)")
        }
        if let demand = insights.demandSummary {
            parts.append("Demand: \(demand)")
        }
        if let value = insights.valueSummary {
            parts.append("Value: \(value)")
        }
        if let cost = insights.costSummary {
            parts.append("Cost: \(cost)")
        }
        if let constraints = insights.constraintsConsidered, !constraints.isEmpty {
            parts.append("Constraints considered: \(constraints.joined(separator: ", "))")
        }
        if let philosophy = insights.philosophy {
            parts.append("Philosophy: \(philosophy)")
        }

        // Revenue projections
        if let projections {
            parts.append("\n## Revenue Projections")
            if let tam = projections.tam { parts.append("TAM: \(tam)") }
            if let sam = projections.sam { parts.append("SAM: \(sam)") }
            if let som = projections.som { parts.append("SOM: \(som)") }
            if let tc = projections.toolCount { parts.append("Tool count: \(tc)") }
            if let avg = projections.avgPriceSats { parts.append("Avg price: \(avg) sats") }
            for proj in projections.projections {
                parts.append("- \(proj.scenario): \(proj.monthlyUsers) users, \(proj.callsPerUserPerMonth) calls/user/mo, \(proj.revenueSats) sats/mo ($\(String(format: "%.2f", proj.revenueUsd))/mo)")
            }
        }

        // Final pricing JSON
        if let json = pipelineJSON {
            parts.append("\n## Pricing JSON")
            parts.append("```json")
            parts.append(json)
            parts.append("```")
        }

        // Condensed transcript (assistant messages only, truncated)
        let assistantMessages = messages
            .filter { $0.role == .assistant && !$0.content.isEmpty }
            .map { $0.content }
        let transcript = assistantMessages.joined(separator: "\n\n---\n\n")
        let truncated = transcript.count > 4000
            ? String(transcript.prefix(4000)) + "\n\n[...truncated...]"
            : transcript
        parts.append("\n## Consultant Reasoning (condensed)")
        parts.append(truncated)

        return parts.joined(separator: "\n")
    }

    // MARK: - Reshape Transcript

    /// Build a numbered transcript formatted for stage classification.
    static func buildForReshape(messages: [AssistantMessage]) -> String {
        var transcript = ""
        for (i, msg) in messages.enumerated() {
            let role = msg.role == .user ? "Operator" : "Consultant"
            let preview = String(msg.content.prefix(300))
            transcript += "[\(i)] \(role): \(preview)\n\n"
        }
        return transcript
    }

    // MARK: - Revision Prompt

    /// Build context for a campaign revision incorporating reviewer feedback.
    static func buildForRevision(proposal: PricingProposal?, review: PeerReview?) -> String {
        var parts: [String] = []

        parts.append("## Revision Context")
        parts.append("The pricing campaign has been reviewed by a peer analyst. Please revise the campaign based on their feedback.\n")

        if let proposal, let json = proposal.pipelineJSON {
            parts.append("### Current Pricing JSON")
            parts.append("```json")
            parts.append(json)
            parts.append("```\n")
        }

        if let review {
            parts.append("### Reviewer Feedback (\(review.providerName))")
            if let changes = review.suggestedChanges, !changes.isEmpty {
                parts.append(changes)
            } else {
                parts.append(review.rawResponse)
            }
        }

        return parts.joined(separator: "\n")
    }
}
