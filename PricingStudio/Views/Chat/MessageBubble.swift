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
                },
                trust: trustAssessment
            )
        }
    }

    /// Operator-attested trust verdict for an incoming proof-request DM.
    ///
    /// Uses only data already on the DM — no identity store needed. For a
    /// genuine self-proof the attestation is signed by the operator, and the
    /// DM's recipient *is* that same operator identity, so the signer resolving
    /// to `dm.recipientPubkeyHex` yields green; an impostor who signs with any
    /// other key resolves to nothing and yields red (claimed name suppressed).
    /// Cross-operator resolution against the community registry is a follow-up.
    private var trustAssessment: ProofProvenance.TrustAssessment? {
        guard let payload = courierPayload, !dm.isFromMe else { return nil }
        // Only proof-request DMs (those carrying a one-time challenge) get a
        // verdict; credential-delivery DMs keep the plain provenance popover.
        guard let challenge = payload.poison?.value, !challenge.isEmpty else { return nil }

        let recipientHex = dm.recipientPubkeyHex
        let subjectNpub = (try? NostrKeyService.npubFromHex(recipientHex)) ?? ""

        return ProofProvenance.assess(
            attestationJSON: payload.attestationJSON,
            expectedSenderPubkeyHex: dm.senderPubkeyHex,
            expectedSubjectNpub: subjectNpub,
            expectedChallenge: challenge,
            knownOperatorPubkeyHexes: [recipientHex],
            priorContactPubkeyHexes: [recipientHex],
            // The verified signer resolves to this device's own operator
            // identity (the self-proof case). Show the actual npub, not a
            // placeholder phrase — an unverifiable label ("your operator
            // identity") is exactly the empty text the human cannot check.
            resolvedOperatorName: subjectNpub.isEmpty ? nil : subjectNpub,
            claimedService: payload.provenance.service,
            signatureValidator: { event in
                verifyEventSignature(NostrEvent(
                    id: event.id, pubkey: event.pubkey, created_at: event.created_at,
                    kind: event.kind, tags: event.tags, content: event.content, sig: event.sig
                ))
            }
        )
    }

    /// Reply to the DM sender — the server scans DMs addressed to the
    /// key that sent the welcome, which may be an ephemeral agent keypair.
    private var replyTargetHex: String {
        dm.senderPubkeyHex
    }
}
