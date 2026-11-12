import DPYCAuthKit
import SwiftUI
import PricingStudioCore

/// Renders a Secure Courier request as a native form, drawn from the JSON
/// Schema in the request's `form` tag.
///
/// Secrets (`writeOnly`) are masked with a reveal toggle and a paste button,
/// offered values (`examples`) are quick-pick chips, allowed values (`enum`)
/// are a menu, and each field's `description` sits behind an ⓘ. An approval
/// shows only its choices and a confirm button. `onSend` receives the payload
/// to reply with; the caller sends its JSON content, `e` tag and relay pin.
struct CourierPayloadView: View {
    @Binding var payload: CourierPayload
    var onSend: ((CourierPayload) -> Void)?
    /// Operator-attested trust state (green/amber/red), computed by the caller
    /// from the request's `attestation` tag.
    var trust: ProofProvenance.TrustAssessment?

    @State private var showProvenance = false
    @State private var sent = false

    /// True when the trust banner's Device-Grant anchor already surfaces the
    /// nonce as the cross-check value, making the standalone nonce row
    /// redundant.
    private var codeShownInAnchor: Bool {
        if let v = trust?.verifyAt, !v.isEmpty { return true }
        return false
    }

    /// For a peer grant, the name Studio knows the peer by; nil when the peer
    /// is a stranger (or the request is no peer grant).
    private var peerName: String? {
        payload.form.peerNpub.flatMap { IdentityName.known($0) }
    }

    /// A peer grant from an npub Studio does not know: approve with care.
    private var strangerPeer: Bool {
        payload.form.isPeerGrant && peerName == nil
    }

    /// The fields an approval lets the patron choose (how long to remember
    /// it). Every other approval field is answered "approved" on send.
    private var approvalChoices: [Binding<CourierPayload.Field>] {
        $payload.fields.filter {
            !$0.wrappedValue.property.examples.isEmpty || !$0.wrappedValue.property.allowed.isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let trust {
                trustBanner(trust)
            }

            // The form's title is meaningful for a credential request
            // ("Schwab operator credentials"). For an approval it is the request
            // type — noise — and on red it is an unverified claim, so neither
            // shows it.
            HStack(spacing: 8) {
                if !payload.isApproval, trust?.level != .red, !payload.form.title.isEmpty {
                    Label(payload.form.title, systemImage: "lock.shield")
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

            // The operator's greeting. An approval's greeting repeats what the
            // trust banner and the signed reason already say, so it is hidden.
            if let greeting = payload.form.description, !payload.isApproval {
                Text(greeting)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let peer = payload.form.peerNpub {
                peerRow(peer)
            }

            if payload.isApproval {
                ForEach(approvalChoices) { $field in
                    CourierFieldRow(field: $field)
                }
            } else {
                VStack(spacing: 10) {
                    ForEach($payload.fields) { $field in
                        CourierFieldRow(field: $field)
                    }
                }
            }

            // Nonce (read-only). Hidden when the Device-Grant anchor already
            // presents this same code as the human's cross-check value.
            if !codeShownInAnchor {
                HStack(spacing: 8) {
                    Image(systemName: "shield.checkered")
                        .foregroundStyle(.purple)
                        .font(.caption)
                    Text("Anti-replay:")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(payload.nonce)
                        .font(.caption.monospaced())
                        .foregroundStyle(.purple)
                        .textSelection(.enabled)
                }
                .padding(8)
                .background(Color.purple.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if let onSend {
                if payload.isApproval {
                    // For an unverified (red) request the safe default is to NOT
                    // approve, so the affordance is de-emphasized and captioned;
                    // ignoring the request is a first-class outcome.
                    VStack(spacing: 4) {
                        Button {
                            onSend(payload.approved())
                            sent = true
                        } label: {
                            Label(
                                sent ? "Reply sent" : (trust?.level == .red || strangerPeer ? "Approve anyway & reply" : "Confirm & reply"),
                                systemImage: sent ? "checkmark.circle.fill" : "paperplane.fill"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(sent ? .secondary : (trust?.level == .red ? .red : (strangerPeer ? .orange : .accentColor)))
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
                        onSend(payload)
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

    // MARK: - Peer

    /// Who would see this account and pay for it: a name Studio knows, or a
    /// warning and the raw npub.
    @ViewBuilder
    private func peerRow(_ peer: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let peerName {
                Label(peerName, systemImage: "person.crop.circle.badge.checkmark")
                    .font(.subheadline.bold())
                    .foregroundStyle(.green)
            } else {
                Label("Unknown npub", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)
                Text(peer)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            Text("May see this account and pay for it. Cannot spend it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((peerName == nil ? Color.orange : Color.green).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Trust Banner

    private func trustColor(_ level: ProofProvenance.TrustLevel) -> Color {
        switch level {
        case .green: return .green
        case .amber: return .orange
        case .ephemeral: return .purple
        case .red: return .red
        }
    }

    private func trustIcon(_ level: ProofProvenance.TrustLevel) -> String {
        switch level {
        case .green: return "checkmark.seal.fill"
        case .amber: return "exclamationmark.triangle.fill"
        case .ephemeral: return "person.fill.questionmark"
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
                            (Text("See ").foregroundStyle(.secondary)
                             + Text(verifyAt).bold()
                             + Text(" for the code to validate this.").foregroundStyle(.secondary))
                                .font(.caption2)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "checkmark.shield").font(.caption2).foregroundStyle(color)
                        }
                        if !payload.nonce.isEmpty {
                            let code = payload.nonce
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
                        Text("Approve only if it matches. If you can't find it, don't approve.")
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
                        Text("Validity Parameters")
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

    // MARK: - Provenance

    /// The operator that signed the request (from its attestation), and the
    /// relay the reply goes to. Whether to trust the signer is the banner's
    /// job; this only names it.
    @ViewBuilder
    private var provenanceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let json = payload.attestationJSON,
               let event = ProofProvenance.parse(json),
               let npub = try? NostrKeyService.npubFromHex(event.pubkey) {
                provenanceRow("person.fill", "Operator", npub)
            }
            provenanceRow("antenna.radiowaves.left.and.right", "Reply via", payload.rendezvousRelay.absoluteString)
            if !payload.form.service.isEmpty {
                provenanceRow("tag", "Service", payload.form.service)
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

// MARK: - Field Row

/// One form field, drawn by what its schema says it is.
private struct CourierFieldRow: View {
    @Binding var field: CourierPayload.Field

    @State private var revealed = false
    @State private var showHelp = false

    private var property: CourierForm.Property { field.property }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: field.needsInput ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(field.problem != nil ? .red : (field.needsInput ? .orange : .green))
                    .font(.caption)
                Text(property.title)
                    .font(.caption.bold())
                if property.isRequired {
                    Circle()
                        .fill(.orange)
                        .frame(width: 5, height: 5)
                        .accessibilityLabel("Required")
                }
                if let help = property.description {
                    Button {
                        showHelp.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("About \(property.title)")
                    .popover(isPresented: $showHelp) {
                        Text(help)
                            .font(.caption)
                            .padding()
                            .presentationCompactAdaptation(.popover)
                    }
                }
                Spacer()
            }

            if !property.allowed.isEmpty {
                Picker(property.title, selection: $field.value) {
                    Text("Choose…").tag("")
                    ForEach(property.allowed, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
            } else {
                input
                if !property.examples.isEmpty {
                    choices
                }
            }

            if let problem = field.problem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    /// The text entry: masked for a secret unless revealed, growing for long
    /// values (a PEM key) otherwise.
    @ViewBuilder
    private var input: some View {
        HStack(spacing: 6) {
            Group {
                if property.isSecret && !revealed {
                    SecureField(property.title, text: $field.value)
                } else {
                    TextField(property.title, text: $field.value, axis: .vertical)
                        .lineLimit(1...6)
                }
            }
            .font(.system(.callout, design: .monospaced))
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)

            if property.isSecret {
                Button {
                    revealed.toggle()
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(revealed ? "Hide \(property.title)" : "Show \(property.title)")
            }
            Button {
                if let pasted = UIPasteboard.general.string {
                    field.value = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Paste \(property.title)")
        }
    }

    /// The offered values, one tap each.
    private var choices: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(property.examples, id: \.self) { example in
                    let chosen = field.value == example
                    Button(example) { field.value = example }
                        .font(.caption.monospaced())
                        .buttonStyle(.bordered)
                        .tint(chosen ? .accentColor : .secondary)
                        .controlSize(.small)
                }
            }
        }
    }
}
