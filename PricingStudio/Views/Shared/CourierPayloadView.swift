import SwiftUI
import PricingStudioCore

/// Renders a parsed Secure Courier payload as an editable credential form.
///
/// Displays the greeting, credential fields with inline editing,
/// the anti-replay poison (read-only), and provenance metadata.
/// When the user fills in all fields, the "Send Credentials" button
/// serializes and sends the reply via the `onSend` callback.
struct CourierPayloadView: View {
    @Binding var payload: CourierPayload
    var onSend: ((String) -> Void)?
    /// Operator-attested trust state for a proof-request DM (green/amber/red).
    /// Computed by the caller from the embedded provenance attestation; `nil`
    /// for non-proof DMs, which show only the existing provenance metadata.
    var trust: ProofProvenance.TrustAssessment?

    @State private var showProvenance = false
    @State private var sent = false

    /// A proof / approval request carries a one-time challenge but NO editable
    /// credential fields — the reply is a confirmation, not a filled-in form.
    /// It must render as an approval (verdict + stated purpose + confirm/ignore),
    /// never as an empty credential form, which reads as a raw text blob.
    private var isApprovalRequest: Bool {
        payload.fields.isEmpty && payload.poison != nil
    }

    /// True when the trust banner's Device-Grant anchor already surfaces the
    /// dpop code as the cross-check value, making the standalone poison row
    /// redundant.
    private var codeShownInAnchor: Bool {
        if let v = trust?.verifyAt, !v.isEmpty { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Trust banner — the human-facing verdict on who is really asking.
            if let trust {
                trustBanner(trust)
            }

            // Provenance (compact, at top — metadata, not an action).
            // A red verdict SUPPRESSES the requester-asserted service label:
            // rendering an unverified name manufactures confidence the protocol
            // has not earned.
            HStack(spacing: 8) {
                if let service = payload.provenance.service, trust?.level != .red {
                    Label(service, systemImage: "lock.shield")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(Capsule())
                }
                Spacer()
                Button {
                    showProvenance.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showProvenance) {
                    provenanceSection
                        .padding()
                        .presentationCompactAdaptation(.popover)
                }
            }

            // Greeting
            if !payload.greeting.isEmpty {
                Text(payload.greeting)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Credential fields — a proof/approval request has none, so skip
            // the empty form (rendering it is what read as "raw").
            if !isApprovalRequest {
                VStack(spacing: 8) {
                    ForEach($payload.fields) { $field in
                        fieldRow(field: $field)
                    }
                }
            }

            // Poison (read-only). Hidden when the Device-Grant anchor already
            // presents this same code as the human's cross-check value — showing
            // it twice under two labels ("Code" and "Anti-replay") reads as two
            // different codes.
            if let poison = payload.poison, !codeShownInAnchor {
                HStack(spacing: 8) {
                    Image(systemName: "shield.checkered")
                        .foregroundStyle(.purple)
                        .font(.caption)
                    Text("Anti-replay:")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(poison.value)
                        .font(.caption.monospaced())
                        .foregroundStyle(.purple)
                        .textSelection(.enabled)
                }
                .padding(8)
                .background(Color.purple.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Action
            if let onSend {
                if isApprovalRequest {
                    // No fields to fill — the reply is a confirmation. For an
                    // unverified (red) request the safe default is to NOT
                    // approve, so the affordance is de-emphasized and captioned;
                    // ignoring the request is a first-class outcome (just leave).
                    VStack(spacing: 4) {
                        Button {
                            onSend(payload.serialize())
                            sent = true
                        } label: {
                            Label(
                                sent ? "Reply sent" : (trust?.level == .red ? "Approve anyway & reply" : "Confirm & reply"),
                                systemImage: sent ? "checkmark.circle.fill" : "paperplane.fill"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(sent ? .secondary : (trust?.level == .red ? .red : .accentColor))
                        .disabled(sent)

                        if trust?.level == .red && !sent {
                            Text("This request is not verified. Only reply if you started it — otherwise just ignore it.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                } else {
                    Button {
                        let serialized = payload.serialize()
                        onSend(serialized)
                        sent = true
                    } label: {
                        Label(
                            sent ? "Credentials Sent" : (payload.canSend ? "Send Filled Fields" : "Fill at Least One Field"),
                            systemImage: sent ? "checkmark.circle.fill" : "paperplane.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(sent ? .secondary : (payload.canSend ? .accentColor : .gray))
                    .disabled(sent || !payload.canSend)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Trust Banner

    private func trustColor(_ level: ProofProvenance.TrustLevel) -> Color {
        switch level {
        case .green: return .green
        case .amber: return .orange
        case .red: return .red
        }
    }

    private func trustIcon(_ level: ProofProvenance.TrustLevel) -> String {
        switch level {
        case .green: return "checkmark.seal.fill"
        case .amber: return "exclamationmark.triangle.fill"
        case .red: return "xmark.octagon.fill"
        }
    }

    /// One labelled row in the "How this was decided" disclosure.
    @ViewBuilder
    private func factRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Abbreviate a 64-char hex pubkey for a scannable disclosure row.
    private func shortHex(_ hex: String) -> String {
        hex.count > 16 ? "\(hex.prefix(8))…\(hex.suffix(8))" : hex
    }

    /// Abbreviate a bech32 npub for a scannable disclosure row.
    private func shortNpub(_ npub: String) -> String {
        npub.count > 20 ? "\(npub.prefix(12))…\(npub.suffix(6))" : npub
    }

    @ViewBuilder
    private func trustBanner(_ trust: ProofProvenance.TrustAssessment) -> some View {
        let color = trustColor(trust.level)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: trustIcon(trust.level))
                .foregroundStyle(color)
                .font(.callout)
            VStack(alignment: .leading, spacing: 2) {
                Text(trust.headline)
                    .font(.caption.bold())
                    .foregroundStyle(color)
                // A verified identity, rendered plainly as trustworthy.
                if let identity = trust.resolvedIdentity {
                    Text(identity)
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                // An unverified claim (unknown-signer red): shown so the human
                // can catch an impostor, explicitly labelled so it never reads
                // as endorsed.
                if let claimed = trust.claimedIdentity {
                    (Text("Claims to be ")
                        .foregroundStyle(.secondary)
                     + Text(claimed).font(.caption2.monospaced())
                     + Text(" — unverified, not in your registry")
                        .foregroundStyle(.secondary))
                        .font(.caption2)
                        .lineLimit(2)
                }
                Text(trust.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // The Operator's stated, signature-bound purpose — the "why"
                // that makes a stranger's ask judgeable. Shown as what the
                // signer *said*, labelled unverified, never as an endorsement.
                if let reason = trust.reason, !reason.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "quote.bubble")
                            .font(.caption2)
                            .foregroundStyle(color)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Stated purpose")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(reason)
                                .font(.caption2)
                                .italic()
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(color.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 2)
                }
                // Operator-observed origin of the client that triggered this
                // request — where it came from, so an unsolicited ask is
                // judgeable, not just signable.
                if let origin = trust.origin, !origin.isEmpty {
                    Label {
                        (Text("Request origin: ").foregroundStyle(.secondary)
                         + Text(origin))
                            .font(.caption2)
                            .lineLimit(2)
                    } icon: {
                        Image(systemName: "globe").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.top, 1)
                }
                // Device-Grant cross-check anchor (RFC 8628): the agent stated
                // it already showed the human this code at `verifyAt`. The code
                // is the same one carried in this DM. The human approves iff the
                // two match — an impostor cannot forge the code on the human's
                // own surface, so an unreachable venue fails safe.
                if let verifyAt = trust.verifyAt, !verifyAt.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Label {
                            (Text("Also shown to you at ").foregroundStyle(.secondary)
                             + Text(verifyAt).bold())
                                .font(.caption2)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "checkmark.shield").font(.caption2).foregroundStyle(color)
                        }
                        if let code = payload.poison?.value, !code.isEmpty {
                            HStack(spacing: 6) {
                                Text("Code")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(code)
                                    .font(.callout.monospaced().bold())
                                    .foregroundStyle(color)
                                    .textSelection(.enabled)
                            }
                        }
                        Text("Approve only if this code matches the one shown there. If you can't find it, don't approve.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(color.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 2)
                }
                // "How this was decided" — the auditable, signature-bound inputs
                // behind the verdict, so the human can inspect the reasoning
                // rather than take the coloured headline on faith.
                if let facts = trust.decisionFacts {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 3) {
                            factRow("Signature", facts.verificationReason == "ok" ? "verified" : facts.verificationReason)
                            if let signer = facts.signerPubkeyHex {
                                factRow("Signed by", shortHex(signer))
                            }
                            factRow(
                                "Delivered by",
                                shortHex(facts.deliverySenderPubkeyHex)
                                    + (facts.viaDeliveryKey ? "  (one-time key)" : "  (same key)")
                            )
                            factRow("Proof sought of", shortNpub(facts.subjectNpub))
                            factRow("Bound code", facts.challenge)
                        }
                        .padding(.top, 4)
                    } label: {
                        Text("How this was decided")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .tint(.secondary)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(color.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Field Row

    @ViewBuilder
    private func fieldRow(field: Binding<CourierPayload.Field>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: field.wrappedValue.needsInput ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(field.wrappedValue.needsInput ? .orange : .green)
                    .font(.caption)
                Text(field.wrappedValue.key)
                    .font(.caption.bold())
                    .monospaced()
            }

            TextField(
                placeholderText(for: field.wrappedValue),
                text: field.value
            )
            .font(.system(.callout, design: .monospaced))
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        }
    }

    private func placeholderText(for field: CourierPayload.Field) -> String {
        field.needsInput ? "Paste your \(field.key) here" : field.key
    }

    // MARK: - Provenance

    @ViewBuilder
    private var provenanceSection: some View {
        let prov = payload.provenance
        VStack(alignment: .leading, spacing: 4) {
            if let op = prov.operatorNpub {
                provenanceRow("person.fill", "Operator", op)
            }
            if let sent = prov.sent {
                provenanceRow("clock", "Sent", sent)
            }
            if let proto = prov.protocolVersion {
                provenanceRow("shield.lefthalf.filled", "Protocol", proto)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func provenanceRow(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .frame(width: 16)
            Text("\(label):")
                .fontWeight(.medium)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}
