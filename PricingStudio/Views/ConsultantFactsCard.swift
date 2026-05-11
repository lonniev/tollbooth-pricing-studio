import SwiftUI
import UIKit

/// Expanded "facts card" for one consultant — shown as a popover on long-press
/// from a business card. Larger portrait, full bio, birthplace + death, and
/// the 2–4 sentence career summary.
struct ConsultantFactsCard: View {
    let consultant: Consultant

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Divider()
                vitals
                Divider()
                section("Bio", body: consultant.bio)
                section("Career", body: consultant.careerSummary)
                section("Known for", body: consultant.knownFor)
            }
            .padding(18)
        }
        .frame(minWidth: 320, idealWidth: 380, maxWidth: 420, minHeight: 480, idealHeight: 560)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            portrait
                .frame(width: 88, height: 88)
            VStack(alignment: .leading, spacing: 4) {
                Text(consultant.displayName)
                    .font(.title2.bold())
                Text(consultant.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(consultant.accentColor)
                Text(consultant.lifespan)
                    .font(.system(size: 12, weight: .medium, design: .serif))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
            }
            Spacer(minLength: 0)
        }
    }

    private var portrait: some View {
        ZStack {
            Circle()
                .strokeBorder(consultant.accentColor, lineWidth: 3)
            Circle()
                .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                .padding(3)
            Group {
                if let asset = consultant.portraitAssetName,
                   UIImage(named: asset) != nil {
                    Image(asset)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        LinearGradient(
                            colors: [consultant.accentColor.opacity(0.85), consultant.accentColor.opacity(0.45)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        Image(systemName: consultant.avatarSystemName)
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .clipShape(Circle())
            .padding(5)
        }
    }

    private var vitals: some View {
        VStack(alignment: .leading, spacing: 6) {
            vitalRow(icon: "leaf.fill", label: "Born", value: consultant.birthplace)
            vitalRow(icon: "moon.stars.fill", label: "Died", value: consultant.deathPlace)
            vitalRow(icon: "globe.europe.africa.fill", label: "Nationality", value: consultant.nationality)
        }
    }

    private func vitalRow(icon: String, label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(consultant.accentColor)
                .frame(width: 14, alignment: .center)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func section(_ title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.bold())
                .tracking(1.2)
                .foregroundStyle(consultant.accentColor)
            Text(body)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
