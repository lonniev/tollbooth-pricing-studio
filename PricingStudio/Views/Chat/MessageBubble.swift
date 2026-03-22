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
            if dm.isFromMe { Spacer(minLength: 60) }

            VStack(alignment: dm.isFromMe ? .trailing : .leading, spacing: 4) {
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

            if !dm.isFromMe { Spacer(minLength: 60) }
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
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                dm.isFromMe
                    ? Color.accentColor.opacity(0.2)
                    : Color(.secondarySystemBackground)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
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
                onSend: dm.isFromMe ? nil : { serialized in
                    let replyTarget = replyTargetHex
                    onSendReply?(replyTarget, serialized)
                }
            )
        }
    }

    /// Prefer the provenance Operator npub (converted to hex) as the reply
    /// target — this handles ephemeral agent keypairs in self-DM onboarding.
    /// Falls back to the DM sender's pubkey hex.
    private var replyTargetHex: String {
        if let opNpub = courierPayload?.provenance.operatorNpub,
           opNpub.hasPrefix("npub1"),
           let hex = try? NostrKeyService.publicKeyHexFromNpub(opNpub) {
            return hex
        }
        return dm.senderPubkeyHex
    }
}
