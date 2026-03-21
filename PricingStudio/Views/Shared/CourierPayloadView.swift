import SwiftUI

/// Renders a parsed Secure Courier payload as an editable credential form.
///
/// Displays the greeting, credential fields with inline editing,
/// the anti-replay poison (read-only), and provenance metadata.
/// When the user fills in all fields, the "Send Credentials" button
/// serializes and sends the reply via the `onSend` callback.
struct CourierPayloadView: View {
    @Binding var payload: CourierPayload
    var onSend: ((String) -> Void)?

    @State private var showProvenance = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Provenance (compact, at top — metadata, not an action)
            HStack(spacing: 8) {
                if let service = payload.provenance.service {
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
                } label: {
                    Label(
                        payload.isComplete ? "Send Credentials" : "Fill All Fields First",
                        systemImage: "paperplane.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(payload.isComplete ? .accentColor : .gray)
                .disabled(!payload.isComplete)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
            .textFieldStyle(.plain)
            .padding(8)
            .background(Color(.tertiarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
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
