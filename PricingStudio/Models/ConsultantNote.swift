import Foundation

/// One consultant's working notes on the campaign.
///
/// Each consultant accumulates a `ConsultantNote` as the user meets with them.
/// Peers read each other's notes through `read_peer_notes`, and the Managing
/// Partner (Hayek) merges every consultant's `proposedDeltas` into the final
/// deployable `PricingProposal`.
struct ConsultantNote: Codable, Equatable {
    /// First time the user opened this consultant's room. `nil` until first meeting.
    var lastMetAt: Date?

    /// Last time a peer's note changed after this consultant was last met.
    /// Drives the "new input from peers" badge on the business card.
    var lastSawPeerUpdateAt: Date?

    /// One-paragraph summary the consultant maintains: "what I have concluded so far."
    /// Updated by the consultant via `update_summary` tool; surfaced on the business card
    /// and in peer briefings.
    var summary: String

    /// Structured proposed edits to the working pricing model.
    /// Inline chat bubbles render each delta as the consultant proposes it.
    var proposedDeltas: [PricingDelta]

    /// Things the consultant wants the user to decide before they can finalize.
    var openQuestions: [String]

    /// Critiques of peer consultants' work — keyed by peer's stage number.
    /// Surfaced when the user visits the critiqued peer.
    var concernsAboutPeers: [Int: String]

    init(
        lastMetAt: Date? = nil,
        lastSawPeerUpdateAt: Date? = nil,
        summary: String = "",
        proposedDeltas: [PricingDelta] = [],
        openQuestions: [String] = [],
        concernsAboutPeers: [Int: String] = [:]
    ) {
        self.lastMetAt = lastMetAt
        self.lastSawPeerUpdateAt = lastSawPeerUpdateAt
        self.summary = summary
        self.proposedDeltas = proposedDeltas
        self.openQuestions = openQuestions
        self.concernsAboutPeers = concernsAboutPeers
    }

    static let empty = ConsultantNote()

    enum CodingKeys: String, CodingKey {
        case lastMetAt = "last_met_at"
        case lastSawPeerUpdateAt = "last_saw_peer_update_at"
        case summary
        case proposedDeltas = "proposed_deltas"
        case openQuestions = "open_questions"
        case concernsAboutPeers = "concerns_about_peers"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastMetAt = try c.decodeIfPresent(Date.self, forKey: .lastMetAt)
        lastSawPeerUpdateAt = try c.decodeIfPresent(Date.self, forKey: .lastSawPeerUpdateAt)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        proposedDeltas = try c.decodeIfPresent([PricingDelta].self, forKey: .proposedDeltas) ?? []
        openQuestions = try c.decodeIfPresent([String].self, forKey: .openQuestions) ?? []
        // JSON object keys are strings; convert back to Int.
        let stringKeyed = try c.decodeIfPresent([String: String].self, forKey: .concernsAboutPeers) ?? [:]
        var intKeyed: [Int: String] = [:]
        for (k, v) in stringKeyed {
            if let n = Int(k) { intKeyed[n] = v }
        }
        concernsAboutPeers = intKeyed
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(lastMetAt, forKey: .lastMetAt)
        try c.encodeIfPresent(lastSawPeerUpdateAt, forKey: .lastSawPeerUpdateAt)
        try c.encode(summary, forKey: .summary)
        try c.encode(proposedDeltas, forKey: .proposedDeltas)
        try c.encode(openQuestions, forKey: .openQuestions)
        let stringKeyed = Dictionary(uniqueKeysWithValues: concernsAboutPeers.map { (String($0.key), $0.value) })
        try c.encode(stringKeyed, forKey: .concernsAboutPeers)
    }
}

/// A single proposed edit to the working pricing model.
///
/// Modeled as a discriminated record so it round-trips cleanly through Claude
/// tool-use JSON and through the `Campaign` SwiftData blob. The consultant
/// produces these via `propose_delta` tool calls; Hayek merges them into the
/// canonical `PricingProposal` on synthesis.
struct PricingDelta: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case toolPrice = "tool_price"
        case addConstraint = "add_constraint"
        case removeConstraint = "remove_constraint"
        case projectionAssumption = "projection_assumption"
    }

    let id: UUID
    let kind: Kind
    let proposedAt: Date
    let proposedByStage: Int
    let rationale: String
    /// Kind-specific fields, kept as a flat string-keyed map for tool-use simplicity.
    /// See `PricingDelta+Payloads.swift` (added in a later step) for typed accessors.
    let payload: [String: String]

    init(
        id: UUID = UUID(),
        kind: Kind,
        proposedAt: Date = Date(),
        proposedByStage: Int,
        rationale: String,
        payload: [String: String]
    ) {
        self.id = id
        self.kind = kind
        self.proposedAt = proposedAt
        self.proposedByStage = proposedByStage
        self.rationale = rationale
        self.payload = payload
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case proposedAt = "proposed_at"
        case proposedByStage = "proposed_by_stage"
        case rationale
        case payload
    }
}
