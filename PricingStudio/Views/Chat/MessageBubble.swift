import DPYCAuthKit
import PricingStudioCore
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
    @State private var courierReplyExpanded = false

    var body: some View {
        HStack {
            if !dm.isFromMe { Spacer(minLength: 60) }

            VStack(alignment: dm.isFromMe ? .leading : .trailing, spacing: 4) {
                if let _ = courierPayload, !dm.isFromMe {
                    courierContent
                } else if dm.content.hasPrefix("ncred1") {
                    ncredContent
                } else {
                    plainContent
                }

                HStack(spacing: 4) {
                    // Actor + direction indicator
                    Text(dm.isFromMe ? "\u{1F464}\u{2192}" : "\u{2190}\u{1F916}")
                        .font(.caption2)

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

    /// True if this is an outbound Secure Courier reply (contains filled @@@ fields).
    private var isOutboundCourierReply: Bool {
        dm.isFromMe && dm.content.contains("@@@") && !dm.content.contains("PASTE_YOUR_")
    }

    /// Count of fields in an outbound courier reply.
    private var courierFieldCount: Int {
        dm.content.components(separatedBy: "@@@").count / 2
    }

    @ViewBuilder
    private var plainContent: some View {
        Group {
            if isOutboundCourierReply {
                VStack(alignment: .leading, spacing: 4) {
                    // Compact summary — tap to expand
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Secure Courier reply sent")
                                .font(.caption.bold())
                            Text("\(courierFieldCount) credential\(courierFieldCount == 1 ? "" : "s") delivered")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: courierReplyExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation { courierReplyExpanded.toggle() }
                    }

                    if courierReplyExpanded {
                        Divider()
                        Text(dm.content)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
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
        }
    }

    // MARK: - Credential Card (ncred)

    @ViewBuilder
    private var ncredContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "creditcard.fill")
                    .foregroundStyle(.green)
                Text("Credential Card")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
            }
            Text("Save this card to reuse your credentials next time.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(dm.content)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
        }
        .padding(10)
        .background(Color.green.opacity(0.1))
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
