import SwiftUI
import UIKit

/// One consultant's business card — Topps-baseball-card-style.
///
/// Composition (top to bottom):
///   • Bubble head — circular portrait with accent ring. When `consultant.portraitAssetName`
///     resolves to an image in the asset catalog it's used; otherwise we render a tinted
///     gradient with the SF Symbol overlaid as a placeholder.
///   • Name band — bold display name.
///   • Sub-band — lifespan (small caps) and nationality.
///   • Title strip — the consultant's role on the team, in the accent color.
///   • Footer dots — status indicators (visited / new-since-visit / open-question).
struct ConsultantBusinessCard: View {
    let consultant: Consultant
    let state: CardState
    var compact: Bool = false
    var onTap: (() -> Void)? = nil

    @State private var showingFacts = false

    enum CardState: Equatable {
        case unvisited
        case active
        case visited(hasOpenQuestions: Bool, hasNewPeerInput: Bool)
    }

    var body: some View {
        cardContent
            // A visible ⓘ makes the bio discoverable — the long-press alone is
            // invisible. Tapping it opens the same facts popover.
            .overlay(alignment: .topTrailing) {
                Button {
                    showingFacts = true
                } label: {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: compact ? 13 : 15))
                        .foregroundStyle(consultant.accentColor, .background)
                        .padding(compact ? 3 : 5)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show \(consultant.displayName)'s bio")
            }
            .contentShape(.rect)
            .onTapGesture { onTap?() }
            .onLongPressGesture(minimumDuration: 0.45) { showingFacts = true }
            // Regular width: a light popover anchored to the card. Compact
            // (iPhone): let it adapt to a sheet the reader can drag up from a
            // peek to full screen — no longer trapped inside the card's span.
            .popover(isPresented: $showingFacts, arrowEdge: .top) {
                ConsultantFactsCard(consultant: consultant)
                    .presentationDetents([.medium, .large])
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(consultant.displayName), \(consultant.title)")
            .accessibilityHint(accessibilityHint)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: Text("Show facts")) { showingFacts = true }
    }

    private var cardContent: some View {
        VStack(spacing: compact ? 4 : 6) {
            bubbleHead
                .frame(width: compact ? 44 : 64, height: compact ? 44 : 64)

            VStack(spacing: 1) {
                Text(consultant.displayName)
                    .font(compact ? .caption.bold() : .subheadline.bold())
                    .lineLimit(1)
                Text(consultant.lifespan)
                    .font(.system(size: compact ? 8 : 10, weight: .medium, design: .serif))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
            }

            Text(consultant.title)
                .font(.system(size: compact ? 9 : 11, weight: .semibold))
                .foregroundStyle(consultant.accentColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 4)

            statusFooter
        }
        .padding(compact ? 6 : 10)
        .frame(width: compact ? 96 : 130)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.background)
                .shadow(color: .black.opacity(state == .active ? 0.18 : 0.06), radius: state == .active ? 6 : 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(borderColor, lineWidth: state == .active ? 2.5 : 1)
        )
        .saturation(state == .unvisited ? 0.3 : 1.0)
        .opacity(state == .unvisited ? 0.78 : 1.0)
    }

    // MARK: - Subviews

    private var bubbleHead: some View {
        ZStack {
            // Outer accent ring
            Circle()
                .strokeBorder(consultant.accentColor, lineWidth: state == .active ? 3 : 2)
            // Inner white ring (separates portrait from outer ring — Topps look)
            Circle()
                .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                .padding(2.5)
            // Portrait OR placeholder
            portraitOrPlaceholder
                .clipShape(Circle())
                .padding(4)
        }
    }

    @ViewBuilder
    private var portraitOrPlaceholder: some View {
        if let assetName = consultant.portraitAssetName,
           let _ = UIImage(named: assetName) {
            Image(assetName)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            // Placeholder: gradient disc with SF Symbol — visually distinct per consultant
            // until real PD portraits are dropped into Assets.xcassets.
            ZStack {
                LinearGradient(
                    colors: [consultant.accentColor.opacity(0.85), consultant.accentColor.opacity(0.45)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: consultant.avatarSystemName)
                    .font(.system(size: compact ? 18 : 26, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    private var statusFooter: some View {
        HStack(spacing: 4) {
            switch state {
            case .unvisited:
                Text("Tap to meet")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
            case .active:
                Circle().fill(consultant.accentColor).frame(width: 6, height: 6)
                Text("In session")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(consultant.accentColor)
            case .visited(let hasOpen, let hasNew):
                if hasNew {
                    Circle().fill(.orange).frame(width: 6, height: 6)
                    Text("New peer input")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.orange)
                } else if hasOpen {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.yellow)
                    Text("Has questions")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.green)
                    Text("Visited")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 12)
    }

    private var borderColor: Color {
        switch state {
        case .active: return consultant.accentColor
        case .visited: return .secondary.opacity(0.4)
        case .unvisited: return .secondary.opacity(0.25)
        }
    }

    private var accessibilityHint: String {
        switch state {
        case .unvisited: return "Not yet met. Tap to begin."
        case .active: return "Currently in session."
        case .visited(let hasOpen, let hasNew):
            if hasNew { return "Visited; peers have updated since." }
            if hasOpen { return "Visited; has open questions for you." }
            return "Visited."
        }
    }
}
