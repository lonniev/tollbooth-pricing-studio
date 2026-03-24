import SwiftUI

/// Individual message bubble with left/right alignment and encryption badge.
///
/// When a DM contains Secure Courier `@@@` credential fields, renders an
/// interactive `CourierPayloadView` instead of plain text.
struct MessageBubble: View {
    let dm: DecryptedDM
    let fontName: String
    let fontSize: CGFloat
    let isSelected: Bool
    var isPending: Bool = false
    var onSendReply: ((String, String) -> Void)?

    @State private var courierPayload: CourierPayload?
    @State private var didParse = false

    var body: some View {
        HStack {
            if !dm.isFromMe { Spacer(minLength: 60) }

            VStack(alignment: dm.isFromMe ? .leading : .trailing, spacing: 4) {
                if let _ = courierPayload {
                    courierContent
                } else {
                    plainContent
                }

                HStack(spacing: 4) {
                    // Encryption badge
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                    Text(dm.encryption.rawValue)
                        .font(.caption2)

                    Text(dm.createdAt, style: .time)
                        .font(.caption2)

                    if isPending {
                        Image(systemName: "clock")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if courierPayload != nil {
                        Image(systemName: "lock.shield")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .foregroundStyle(.tertiary)
            }

            if dm.isFromMe { Spacer(minLength: 60) }
        }
        .opacity(isPending ? 0.6 : 1.0)
        .accessibilityIdentifier("messageBubble_\(dm.id)")
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.accentColor, lineWidth: isSelected ? 2 : 0)
                .padding(-4)
        )
        .onAppear {
            if !didParse {
                courierPayload = CourierPayload.parse(dm.content)
                didParse = true
            }
        }
    }

    // MARK: - Plain Text Content

    @ViewBuilder
    private var plainContent: some View {
        Text(dm.content)
            .font(.custom(fontName, size: fontSize))
            .italic(isPending)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                dm.isFromMe
                    ? Color.accentColor.opacity(isPending ? 0.1 : 0.2)
                    : Color(.secondarySystemBackground)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                isPending
                    ? RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.secondary)
                    : nil
            )
    }

    // MARK: - Courier Payload Content

    @ViewBuilder
    private var courierContent: some View {
        if courierPayload != nil {
            CourierPayloadView(
                payload: Binding(
                    get: { courierPayload! },
                    set: { courierPayload = $0 }
                ),
                onSend: { serialized in
                    let replyTarget = replyTargetHex
                    onSendReply?(replyTarget, serialized)
                }
            )
        }
    }

    /// Reply to the DM sender — the server scans DMs addressed to the
    /// key that sent the welcome, which may be an ephemeral agent keypair.
    private var replyTargetHex: String {
        dm.senderPubkeyHex
    }
}
