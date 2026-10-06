import SwiftUI
import PricingStudioCore

/// Per-row Rotate for a single vaulted operator secret (issue #153).
///
/// Prefers the wheel's `update_operator_credential(field, value)` tool — a
/// surgical merge that rewrites one field and leaves every other vaulted
/// secret alone. When that tool is missing (older wheel), falls back to the
/// Secure Courier path with only this field listed, so a partial reply still
/// merges surgically via `receive_credentials`.
struct RotateCredentialSheet: View {
    let fieldKey: String
    let operatorName: String
    let operatorNpub: String
    let endpointURL: URL
    let credentialService: String
    /// Optional Secure Courier fallback when the direct tool is unavailable.
    var onRequestCourier: ((CourierParams) -> Void)?
    var onFinished: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var phase: Phase = .edit
    @State private var statusMessage = ""

    private enum Phase {
        case edit, saving, done, failed
    }

    private var fieldLabel: String {
        OperatorSecretRotation.fieldLabel(fieldKey)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(fieldLabel)
                        .font(.headline)
                    Text(operatorName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("Only this secret is rewritten. Every other vaulted credential stays as it is.")
                }

                Section("New value") {
                    SecureField("Paste the new secret", text: $value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .accessibilityIdentifier("rotateCredentialValue")
                }

                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        HStack {
                            if phase == .saving { ProgressView().controlSize(.small) }
                            Text(phase == .saving ? "Rotating…" : "Rotate \(fieldLabel)")
                        }
                    }
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || phase == .saving || phase == .done)
                    .accessibilityIdentifier("rotateCredentialConfirm")

                    if phase == .failed, onRequestCourier != nil {
                        Button {
                            fallbackToCourier()
                        } label: {
                            Label("Use Secure Courier instead", systemImage: "lock.shield")
                        }
                        .accessibilityIdentifier("rotateCredentialCourierFallback")
                    }
                } footer: {
                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .foregroundStyle(phase == .failed ? .red : .green)
                    }
                }
            }
            .navigationTitle("Rotate Secret")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if phase == .done {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            onFinished?()
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private func save() async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        phase = .saving
        statusMessage = ""
        do {
            let msg = try await MCPService().callUpdateOperatorCredential(
                endpointURL: endpointURL,
                npub: operatorNpub,
                field: fieldKey,
                value: trimmed
            )
            statusMessage = msg
            phase = .done
            // Clear the secret from memory once accepted.
            value = ""
            onFinished?()
        } catch {
            statusMessage = error.localizedDescription
            phase = .failed
        }
    }

    private func fallbackToCourier() {
        let plan = OperatorSecretRotation.planSingleRotation(
            fieldKey: fieldKey,
            configured: [
                OperatorSecretRotation.Field(
                    key: fieldKey, category: "secret", isConfigured: true
                )
            ]
        )
        onRequestCourier?(CourierParams(
            operatorName: operatorName,
            operatorNpub: operatorNpub,
            endpointURL: endpointURL,
            credentialService: credentialService,
            missingSecrets: OperatorSecretRotation.courierSecretLabels(for: plan),
            mode: .rotate
        ))
        dismiss()
    }
}
