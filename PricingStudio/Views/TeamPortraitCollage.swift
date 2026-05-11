import SwiftUI
import UIKit

/// A team-pitch icon: small circular portraits of all six consultants,
/// slightly overlapping. Used on the Final Proposal tile to signal that
/// the proposal is the team's product, not any one consultant's monologue.
struct TeamPortraitCollage: View {
    var diameter: CGFloat = 28
    /// Pixels by which each portrait overlaps the previous one.
    var overlap: CGFloat = 10
    /// Border ring color around each portrait. Use white on dark gradient backgrounds.
    var ringColor: Color = .white

    var body: some View {
        let consultants = ConsultantRoster.all
        HStack(spacing: -overlap) {
            ForEach(Array(consultants.enumerated()), id: \.element.id) { index, c in
                portrait(for: c)
                    .zIndex(Double(consultants.count - index))
            }
        }
    }

    private func portrait(for consultant: Consultant) -> some View {
        ZStack {
            Circle()
                .strokeBorder(ringColor, lineWidth: 1.5)
            Group {
                if let asset = consultant.portraitAssetName,
                   UIImage(named: asset) != nil {
                    Image(asset)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(
                        colors: [consultant.accentColor.opacity(0.85), consultant.accentColor.opacity(0.45)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .overlay(
                        Image(systemName: consultant.avatarSystemName)
                            .font(.system(size: diameter * 0.4, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                }
            }
            .clipShape(Circle())
            .padding(2)
        }
        .frame(width: diameter, height: diameter)
    }
}
