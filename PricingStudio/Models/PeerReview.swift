import Foundation

/// A structured peer review of a pricing campaign, parsed from a reviewer
/// LLM's response (Grok or Claude).
struct PeerReview: Codable {
    /// Which LLM provider produced this review.
    var providerName: String

    /// The full raw response text.
    var rawResponse: String

    /// Parsed sections (Strengths, Risks, Alternatives, etc.).
    var sections: [ReviewSection]

    /// Overall verdict, if detected.
    var verdict: ReviewVerdict?

    /// The alternative pricing suggestions text, if the reviewer recommended changes.
    var suggestedChanges: String?

    /// When this review was produced.
    var reviewedAt: Date

    init(
        providerName: String,
        rawResponse: String,
        sections: [ReviewSection] = [],
        verdict: ReviewVerdict? = nil,
        suggestedChanges: String? = nil,
        reviewedAt: Date = Date()
    ) {
        self.providerName = providerName
        self.rawResponse = rawResponse
        self.sections = sections
        self.verdict = verdict
        self.suggestedChanges = suggestedChanges
        self.reviewedAt = reviewedAt
    }
}

/// A titled section within a peer review.
struct ReviewSection: Codable, Identifiable {
    var id: String { title }
    let title: String
    let icon: String
    let content: String
    let verdict: ReviewVerdict?

    init(title: String, icon: String, content: String, verdict: ReviewVerdict? = nil) {
        self.title = title
        self.icon = icon
        self.content = content
        self.verdict = verdict
    }
}

/// Verdict categories a reviewer can assign to a campaign.
enum ReviewVerdict: String, Codable {
    case approve
    case approveWithReservations
    case reworkRecommended
    case reject
}
