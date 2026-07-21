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

            // Credential fields
            VStack(spacing: 8) {
                ForEach($payload.fields) { $field in
                    fieldRow(field: $field)
                }
            }

            // Poison (read-only)
            if let poison = payload.poison {
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

            // Send button
            if let onSend {
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
