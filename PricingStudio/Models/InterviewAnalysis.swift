import Foundation

/// Extracted interview analysis — stage classifications and insights parsed
/// from PROGRESS comments during the pricing consultant interview.
///
/// This is the "what did we learn?" slice — no conversation text, just
/// structured metadata about the interview's progression.
struct InterviewAnalysis: Codable {
    /// Per-message stage classification (1–6), indexed by message position.
    var stageClassifications: [Int]

    /// Insights extracted from PROGRESS comments over the interview.
    var insights: InterviewProgress.Insights

    /// Number of tools identified during inventory phase.
    var toolsIdentified: [String]?

    /// Operator's stated pricing philosophy notes.
    var philosophyNotes: String?

    init(
        stageClassifications: [Int] = [],
        insights: InterviewProgress.Insights = .init(),
        toolsIdentified: [String]? = nil,
        philosophyNotes: String? = nil
    ) {
        self.stageClassifications = stageClassifications
        self.insights = insights
        self.toolsIdentified = toolsIdentified
        self.philosophyNotes = philosophyNotes
    }
}
