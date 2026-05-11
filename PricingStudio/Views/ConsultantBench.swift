import SwiftUI

/// The full team bench: six business cards + a "Prepare Final Proposal" action.
///
/// Renders horizontally as a scrollable strip (suitable for the inline panel
/// at the top of an interview). A vertical layout is available via `axis` for
/// future use in a proper sidebar.
struct ConsultantBench: View {
    let activeStage: Int
    /// Per-stage `ConsultantNote`. Drives card status (visited / new-since-visit / has-open-questions).
    let notes: [Int: ConsultantNote]
    /// Most recent peer-update timestamp across the whole team — used to compute "new since visit."
    let latestPeerUpdate: Date?
    var axis: Axis = .horizontal
    var compact: Bool = false
    var onSelectStage: (Int) -> Void
    var onPrepareFinalProposal: (() -> Void)?

    var body: some View {
        switch axis {
        case .horizontal:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(ConsultantRoster.all) { consultant in
                        ConsultantBusinessCard(
                            consultant: consultant,
                            state: cardState(for: consultant),
                            compact: compact,
                            onTap: { onSelectStage(consultant.stage) }
                        )
                    }
                    if onPrepareFinalProposal != nil {
                        prepareFinalButton
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        case .vertical:
            VStack(spacing: 10) {
                ForEach(ConsultantRoster.all) { consultant in
                    ConsultantBusinessCard(
                        consultant: consultant,
                        state: cardState(for: consultant),
                        compact: compact,
                        onTap: { onSelectStage(consultant.stage) }
                    )
                }
                if onPrepareFinalProposal != nil {
                    prepareFinalButton
                        .padding(.top, 6)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
        }
    }

    private var prepareFinalButton: some View {
        Button {
            onPrepareFinalProposal?()
        } label: {
            VStack(spacing: 6) {
                TeamPortraitCollage(
                    diameter: compact ? 22 : 30,
                    overlap: compact ? 8 : 11,
                    ringColor: .white
                )
                Text("Final Proposal")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                Text("by the Team")
                    .font(.system(size: compact ? 9 : 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(width: compact ? 96 : 130, height: compact ? 100 : 130)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(
                        colors: [.indigo, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
            )
            .shadow(color: .indigo.opacity(0.3), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Final proposal by the team")
        .accessibilityHint("Open the team's consolidated pricing proposal.")
    }

    private func cardState(for consultant: Consultant) -> ConsultantBusinessCard.CardState {
        if consultant.stage == activeStage {
            return .active
        }
        guard let note = notes[consultant.stage], note.lastMetAt != nil else {
            return .unvisited
        }
        let hasOpenQuestions = !note.openQuestions.isEmpty
        let hasNewPeerInput: Bool = {
            guard let lastMet = note.lastMetAt, let latest = latestPeerUpdate else { return false }
            return latest > lastMet
        }()
        return .visited(hasOpenQuestions: hasOpenQuestions, hasNewPeerInput: hasNewPeerInput)
    }
}
