import DPYCAuthKit
import PricingStudioCore
import SwiftUI

/// Individual message bubble with left/right alignment and encryption badge.
///
/// When a DM is a Secure Courier request (its rumor carries a `form` tag),
/// renders an interactive `CourierPayloadView` instead of plain text.
struct MessageBubble: View {
    let dm: DecryptedDM
    let fontName: String
    let fontSize: CGFloat
    let isSelected: Bool
    var isPending: Bool = false
    /// The event reached relays but not the pinned courier rendezvous, so the
    /// courier will never drain it. Delivered to the network is not delivered
    /// to the recipient, and the row must not imply otherwise.
    var missedRendezvous: Bool = false
    /// Operators and Authorities saved in this app, by npub → display name.
    /// A request whose attestation one of them signed resolves to that name.
    var knownOperators: [String: String] = [:]
    /// Send a courier reply: the recipient's hex key and the answered request.
    var onSendCourierReply: ((String, CourierPayload) -> Void)?

    @State private var courierPayload: CourierPayload?
    @State private var didParse = false
    @State private var courierReplyExpanded = false

    var body: some View {
        HStack {
            if !dm.isFromMe { Spacer(minLength: 60) }

            VStack(alignment: dm.isFromMe ? .leading : .trailing, spacing: 4) {
                if let _ = courierPayload, !dm.isFromMe {
                    courierContent
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

                    if missedRendezvous {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Text("missed rendezvous")
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
                courierPayload = CourierPayload.parse(tags: dm.tags, requestId: dm.messageId)
                didParse = true
            }
        }
    }

    // MARK: - Plain Text Content

    /// The field count of an outbound Secure Courier reply, nil otherwise.
    private var courierFieldCount: Int? {
        dm.isFromMe ? CourierPayload.replyFieldCount(dm.content) : nil
    }

    @ViewBuilder
    private var plainContent: some View {
        Group {
            if let courierFieldCount {
                VStack(alignment: .leading, spacing: 4) {
                    // Compact summary — tap to expand
                    HStack(spacing: 6) {
                        Image(systemName: missedRendezvous
                              ? "exclamationmark.triangle.fill" : "lock.shield.fill")
                            .foregroundStyle(missedRendezvous ? .orange : .green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(missedRendezvous
                                 ? "Reply did not reach the courier"
                                 : "Secure Courier reply sent")
                                .font(.caption.bold())
                            Text(missedRendezvous
                                 ? "Sent to other relays, but not to the rendezvous — send again"
                                 : "\(courierFieldCount) credential\(courierFieldCount == 1 ? "" : "s") delivered")
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
                .background((missedRendezvous ? Color.orange : Color.green).opacity(0.15))
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

    // MARK: - Courier Payload Content

    @ViewBuilder
    private var courierContent: some View {
        if courierPayload != nil {
            CourierPayloadView(
                payload: Binding(
                    get: { courierPayload! },
                    set: { courierPayload = $0 }
                ),
                onSend: { answered in
                    onSendCourierReply?(replyTargetHex, answered)
                },
                trust: trustAssessment
            )
        }
    }

    /// Operator-attested trust verdict for an incoming courier request.
    ///
    /// Uses only data already on the DM — no identity store needed. For a
    /// genuine self-proof the attestation is signed by the operator, and the
    /// DM's recipient *is* that same operator identity, so the signer resolving
    /// to `dm.recipientPubkeyHex` yields green; an impostor who signs with any
    /// other key resolves to nothing. A request signed by an Operator or
    /// Authority saved in this app resolves to that saved name.
    private var trustAssessment: ProofProvenance.TrustAssessment? {
        guard let payload = courierPayload, !dm.isFromMe else { return nil }
        // Every request carries a one-time challenge, so every request — a
        // credential form as much as an approval — gets a verdict.
        let challenge = payload.nonce

        let recipientHex = dm.recipientPubkeyHex
        let subjectNpub = (try? NostrKeyService.npubFromHex(recipientHex)) ?? ""

        // Known signers: this device's own identity (the self-proof case) and
        // every Operator or Authority the human saved in this app. The name
        // shown is used only once the signature verifies against that key.
        var known: Set<String> = [recipientHex]
        var signerName: String? = subjectNpub.isEmpty ? nil : subjectNpub
        if let signerHex = payload.attestationJSON.flatMap(ProofProvenance.parse)?.pubkey,
           signerHex != recipientHex,
           let signerNpub = try? NostrKeyService.npubFromHex(signerHex),
           let name = knownOperators[signerNpub] {
            known.insert(signerHex)
            signerName = name.isEmpty ? signerNpub : name
        }

        return ProofProvenance.assess(
            attestationJSON: payload.attestationJSON,
            expectedSenderPubkeyHex: dm.senderPubkeyHex,
            expectedSubjectNpub: subjectNpub,
            expectedChallenge: challenge,
            knownOperatorPubkeyHexes: known,
            // Saving an operator in this app is the standing relationship.
            priorContactPubkeyHexes: known,
            resolvedOperatorName: signerName,
            claimedService: payload.form.title,
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
