import SwiftUI

/// Sheet for re-issuing a credit grant against a known BTCPay invoice ID
/// that didn't land during the original `check_payment` flow.
///
/// **Operator-only since wheel 0.36.0.** The caller MUST hold the
/// operator's nsec in the device Keychain — patrons can't self-serve.
/// Use this sheet from the Operator detail view when supporting a
/// patron's "I paid, never got credits" escalation.
///
/// Internally wraps `MCPService.callRestoreCredits(operatorNpub:)`.
struct RecoverPaymentSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// MCP endpoint of the Operator whose invoice we're trying to recover.
    let operatorEndpoint: URL
    /// Display name of that Operator (for the sheet header).
    let operatorName: String
    /// Default invoice ID to pre-fill (empty = user pastes one).
    let initialInvoiceId: String
    /// Patron whose credits should be restored.
    let patronNpub: String
    /// Whether the patron npub field can be edited (true on the operator
    /// support flow; false on the patron's own Invoices tab — currently
    /// only the operator-side flow is wired, but the toggle stays for the
    /// degraded "no-nsec" branch where the operator-on-this-device assumption
    /// breaks).
    let patronNpubEditable: Bool
    /// The OPERATOR's npub whose nsec signs the restore proof. Wheel
    /// 0.36.0 requires this. The device's Keychain must hold the nsec.
    let operatorNpub: String
    /// Called on success so the caller can refresh balances / invoice list.
    let onSuccess: (() -> Void)?

    @State private var invoiceId: String
    @State private var editablePatronNpub: String
    @State private var status: Status = .idle

    enum Status: Equatable {
        case idle
        case working
        case success(MCPService.RestoreCreditsResult)
        case failed(code: String, message: String)

        static func == (lhs: Status, rhs: Status) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.working, .working): return true
            case (.success(let a), .success(let b)):
                return a.invoiceId == b.invoiceId
            case (.failed(let lc, let lm), .failed(let rc, let rm)):
                return lc == rc && lm == rm
            default: return false
            }
        }
    }

    init(
        operatorEndpoint: URL,
        operatorName: String,
        initialInvoiceId: String = "",
        patronNpub: String,
        patronNpubEditable: Bool = false,
        operatorNpub: String,
        onSuccess: (() -> Void)? = nil
    ) {
        self.operatorEndpoint = operatorEndpoint
        self.operatorName = operatorName
        self.initialInvoiceId = initialInvoiceId
        self.patronNpub = patronNpub
        self.patronNpubEditable = patronNpubEditable
        self.operatorNpub = operatorNpub
        self.onSuccess = onSuccess
        self._invoiceId = State(initialValue: initialInvoiceId)
        self._editablePatronNpub = State(initialValue: patronNpub)
    }

    private var inFlight: Bool { status == .working }

    private var effectivePatronNpub: String {
        editablePatronNpub.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        let id = invoiceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let npub = effectivePatronNpub
        return !id.isEmpty && npub.hasPrefix("npub1") && !inFlight
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Image(systemName: "server.rack")
                            .foregroundStyle(.orange)
                        Text(operatorName)
                            .font(.subheadline.bold())
                    }
                    Text(operatorEndpoint.absoluteString)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } header: {
                    Text("Operator")
                } footer: {
                    Text("Re-issues a credit grant for an invoice that's already settled at BTCPay but didn't land in the patron's ledger.")
                }

                Section {
                    TextField(
                        "Invoice ID",
                        text: $invoiceId,
                        prompt: Text("e.g. Tz1FEve2NQkevpU1MyhByD")
                    )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.callout.monospaced())
                } header: {
                    Text("Invoice ID")
                } footer: {
                    Text("From your wallet receipt, BTCPay dashboard, or the patron's earlier `purchase_credits` response.")
                }

                Section {
                    if patronNpubEditable {
                        TextField(
                            "Patron npub",
                            text: $editablePatronNpub,
                            prompt: Text("npub1…")
                        )
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.callout.monospaced())
                    } else {
                        Text(patronNpub)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Patron")
                } footer: {
                    if patronNpubEditable {
                        Text("The npub whose ledger should receive the credits. Operator support: paste the patron's npub from their escalation.")
                    } else {
                        Text("Your own patron npub — locked.")
                    }
                }

                // -- Status / Result sections -----------------------

                if case .working = status {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Re-checking payment at BTCPay…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if case .success(let result) = status {
                    Section {
                        Label("Credits restored", systemImage: "checkmark.seal.fill")
                            .font(.headline)
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 4) {
                            row("Credits granted", "\(result.creditsGranted) sats")
                            row("New balance", "\(result.balanceApiSats) sats")
                            row("Source", result.source.isEmpty ? "—" : result.source)
                            if !result.persisted {
                                Label("Not yet persisted — retry in a moment", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        if !result.message.isEmpty {
                            Text(result.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if case .failed(let code, let message) = status {
                    Section {
                        Label("Restore failed", systemImage: "xmark.octagon.fill")
                            .font(.headline)
                            .foregroundStyle(.red)
                        if !code.isEmpty {
                            row("Error code", code)
                        }
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(helpForCode(code))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                }
            }
            .navigationTitle("Recover Payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .success = status {
                        Button("Done") { dismiss() }
                    } else {
                        Button("Cancel") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    // Hidden on success — cancellationAction shows Done.
                    if case .success = status {
                        EmptyView()
                    } else {
                        Button("Restore") {
                            Task { await submit() }
                        }
                        .disabled(!canSubmit)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.monospacedDigit())
        }
    }

    /// One-line nudge for the user based on the wheel's error_code. Plain
    /// English; no Studio-protocol jargon. Per `feedback_situations_not_failures`
    /// these are guided retries, not errors.
    private func helpForCode(_ code: String) -> String {
        switch code {
        case "vault_unavailable":
            return "The operator's vault was warming up. Wait ~15 seconds and try again."
        case "operator_nsec_missing":
            return "This device doesn't have the operator's nsec in its Keychain. The patron must escalate to the operator's support — only the operator can restore credits since wheel 0.36.0."
        case "operator_proof_required", "operator_proof_invalid":
            return "The operator's signed proof was rejected. Confirm this device holds the operator's nsec (not the patron's). The Operator's Account tab should show 'nsec' as configured."
        case "proof_required", "proof_invalid", "proof_refresh_needed":
            // Shouldn't normally hit these for restore_credits in 0.36.0+
            // (it's now operator-restricted, not patron-gated), but a
            // pre-0.36.0 operator can still surface them.
            return "Proof rejected. If the operator is on wheel <0.36.0, restore_credits is patron-gated and your patron proof has expired. If 0.36.0+, this device needs the operator's nsec."
        default:
            // Wheel surfaces "Invoice status is 'New', not 'Settled'" verbatim
            // when the patron hasn't paid yet — keep that visible.
            return "Check the invoice ID and patron npub, then try again. If the invoice is still 'New' at BTCPay, the wallet hasn't paid yet."
        }
    }

    private func submit() async {
        let invoice = invoiceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let npub = effectivePatronNpub
        status = .working
        do {
            let result = try await MCPService().callRestoreCredits(
                endpointURL: operatorEndpoint,
                invoiceId: invoice,
                patronNpub: npub,
                operatorNpub: operatorNpub
            )
            status = .success(result)
            onSuccess?()
        } catch let MCPError.structuredError(code, message, _) {
            status = .failed(code: code, message: message)
        } catch {
            status = .failed(code: "", message: error.localizedDescription)
        }
    }
}
