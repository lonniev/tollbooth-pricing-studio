import SwiftUI

/// Individual message bubble with left/right alignment and encryption badge.
struct MessageBubble: View {
    let dm: DecryptedDM
    let fontName: String
    let fontSize: CGFloat
    let isSelected: Bool

    var body: some View {
        HStack {
            if dm.isFromMe { Spacer(minLength: 60) }

            VStack(alignment: dm.isFromMe ? .trailing : .leading, spacing: 4) {
                Text(dm.content)
                    .font(.custom(fontName, size: fontSize))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        dm.isFromMe
                            ? Color.accentColor.opacity(0.2)
                            : Color(.secondarySystemBackground)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                HStack(spacing: 4) {
                    // Encryption badge
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                    Text(dm.encryption.rawValue)
                        .font(.caption2)

                    Text(dm.createdAt, style: .time)
                        .font(.caption2)
                }
                .foregroundStyle(.tertiary)
            }

            if !dm.isFromMe { Spacer(minLength: 60) }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.accentColor, lineWidth: isSelected ? 2 : 0)
                .padding(-4)
        )
    }
}
