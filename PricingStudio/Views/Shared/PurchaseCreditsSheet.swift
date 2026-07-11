import SwiftUI
import UIKit

/// The single "top up your account at your parent" flow, shared by every actor
/// (Patron at its Operator, Operator/sub-Authority at its parent Authority).
/// Pays a Lightning invoice at the cashier's store to credit the purchaser's
/// api_sats balance there, with the inline npub-proof exchange (auto-sign when
/// the purchaser's nsec is in the Keychain, human-in-the-loop otherwise).
///
/// Replaces the former `TopOffSheet` (patron) and `AuthorityTopOffSheet`
/// (authority) — one sheet, parameterized.
struct PurchaseCreditsSheet: View {
    /// The store/vendor receiving the Lightning payment.
    let cashierName: String
    let cashierNpub: String
    let endpoint: String
    /// The npub whose balance is funded — the purchaser/beneficiary.
    let purchaserNpub: String

    /// Caller-supplied beneficiary display name; bypasses the SwiftData walk.
    var beneficiaryDisplayName: String? = nil
    /// Actor glyphs shown on the tranche pass. Defaults suit the most common
    /// flow (a Patron topping up at its Operator); other call sites pass the
    /// matching pair (e.g. Operator → Authority).
    var beneficiaryBadge: ActorBadge = .patron
    var cashierBadge: ActorBadge = .operator
    var presets: [Int] = [100, 500, 1000, 5000]
    var minimumSats: Int = 100
    /// Fired after the payment settles, so the host can refresh whatever balance
    /// it shows. (Direct MCP calls are made here; the host owns its own state.)
    var onSettled: (() -> Void)? = nil
    /// Optional "message the cashier" affordance for unrecoverable errors.
    var onNotifyCashier: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var selectedAmount = 1000
    @State private var customAmount = ""
    /// Whether the full-width "Custom amount" ticket is active. When true the
    /// preset tiles deselect and the inline number pad drives the amount.
    @State private var showCustomField = false
    @FocusState private var customFocused: Bool
    @State private var purchaseState: PurchaseState = .idle
    @State private var paymentCheckState: PaymentCheckState = .idle
    @State private var proofState: ProofExchangeState = .idle
    /// Rendezvous relay the wheel committed for the proof challenge; the
    /// responder must reply there. Empty when the wheel predates pinning.
    @State private var proofRendezvousRelay: String = ""
    /// proof_token (poison) from request_npub_proof, fed to receive_npub_proof.
    @State private var proofToken: String = ""
    /// Opening sheet height. Defaults to ~80% so the amount, invoice, and proof
    /// fields are visible without dragging; `.medium` stays available so the
    /// user can drag down to reach the Messages tab during the proof exchange.
    @State private var detent: PresentationDetent = .fraction(0.8)

    private let mcpService = MCPService()

    private enum PurchaseState {
        case idle, purchasing
        case success(MCPService.PurchaseResult)
        case error(String)
    }

    /// Inline proof-exchange state. (a) auto-sign — App holds the purchaser's
    /// nsec, completes inline (the click is consent). (b) human-in-the-loop —
    /// no nsec; stop at `awaitingReply` until the user replies in their client.
    private enum ProofExchangeState: Equatable {
        case idle, requesting, signingReply, awaitingReply, verifying
        case failed(String)
    }

    private enum PaymentCheckState {
        case idle, checking, settled(String), checked(String)
        var isChecking: Bool { if case .checking = self { return true }; return false }
        var isSettled: Bool { if case .settled = self { return true }; return false }
        var message: String? {
            switch self {
            case .settled(let m), .checked(let m): return m
            default: return nil
            }
        }
    }

    /// The App can finish the proof unaided when the purchaser's nsec is held.
    private var canAutoSign: Bool {
        KeychainService.loadNsec(forNpub: purchaserNpub) != nil
    }

    private var effectiveAmount: Int {
        if showCustomField { return Int(customAmount) ?? 0 }
        return selectedAmount
    }

    /// A preset tile is selected only when the custom pad is inactive.
    private func isPresetSelected(_ amount: Int) -> Bool {
        !showCustomField && selectedAmount == amount
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                heroTicketSection
                amountSection
                purchaseStateSection
            }
            .navigationTitle("Top Up")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(paymentCheckState.isSettled ? "Done" : "Cancel") { dismiss() }
                }
            }
        }
        // Opens at ~80% so the goto fields are visible up front; drag-down
        // detents let the user reach the Messages tab to reply to the
        // proof-challenge DM without losing the in-flight exchange or amount.
        .presentationDetents([.medium, .fraction(0.8), .large], selection: $detent)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationContentInteraction(.scrolls)
    }

    // MARK: - Hero tranche pass

    /// The printed "ticket stub" header: beneficiary + cashier rendered as a
    /// pass you're about to load, with a perforation tear line for flavor.
    private var heroTicketSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "ticket.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                    Text("TRANCHE")
                        .font(.caption.weight(.semibold))
                        .tracking(2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(.yellow)
                }
                .padding(.bottom, 12)

                DashedLine()
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Color(.separator))
                    .frame(height: 1)
                    .padding(.bottom, 12)

                HStack(alignment: .top, spacing: 12) {
                    // Benefitting — the account being funded — on the left.
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 5) {
                            Image(systemName: beneficiaryBadge.icon)
                                .font(.caption)
                                .foregroundStyle(beneficiaryBadge.color)
                            Text("Benefitting")
                                .font(.caption2.weight(.semibold))
                                .tracking(1)
                                .foregroundStyle(.secondary)
                        }
                        beneficiaryLabel(purchaserNpub)
                    }
                    Spacer(minLength: 12)
                    // Cashier — the store receiving the Lightning payment — right.
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: 5) {
                            Text("Cashier")
                                .font(.caption2.weight(.semibold))
                                .tracking(1)
                                .foregroundStyle(.secondary)
                            Image(systemName: cashierBadge.icon)
                                .font(.caption)
                                .foregroundStyle(cashierBadge.color)
                        }
                        Text(cashierName)
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .padding(.top, 2)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
            )
        } header: {
            Text("Top Up your account at \(cashierName)")
        } footer: {
            Text("Sats are credited to the beneficiary's account at \(cashierName). Anyone can pay the Lightning invoice — the source of funds doesn't matter.")
                .font(.caption2)
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowBackground(Color.clear)
    }

    // MARK: - Tranche-card grid

    private var amountSection: some View {
        Section {
            VStack(spacing: 10) {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 10),
                              GridItem(.flexible(), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(presets, id: \.self) { amount in
                        trancheTile(amount: amount)
                    }
                }
                customTile
            }
            .padding(.vertical, 4)
        } header: {
            Text("Choose a tranche")
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowBackground(Color.clear)
    }

    /// A single tappable denomination ticket. Selected → tinted fill, accent
    /// border, and a punched-ticket checkmark.
    private func trancheTile(amount: Int) -> some View {
        let selected = isPresetSelected(amount)
        return Button {
            selectedAmount = amount
            customAmount = ""
            showCustomField = false
            customFocused = false
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "ticket.fill")
                        .font(.title3)
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(amount.formatted())
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(.primary)
                Text("sats")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(trancheTileBackground(selected: selected))
        }
        .buttonStyle(.plain)
    }

    /// The full-width "Custom amount" ticket. Tapping it reveals the number pad.
    private var customTile: some View {
        let selected = showCustomField
        return VStack(spacing: 8) {
            Button {
                showCustomField = true
                customFocused = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "keyboard")
                        .font(.title3)
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                    Text(customLabel)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(customAmount.isEmpty ? .secondary : .primary)
                    Spacer()
                    if selected, !customAmount.isEmpty {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(trancheTileBackground(selected: selected))
            }
            .buttonStyle(.plain)

            if showCustomField {
                TextField("Enter sats", text: $customAmount)
                    .keyboardType(.numberPad)
                    .focused($customFocused)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var customLabel: String {
        if let val = Int(customAmount), val > 0 { return "\(val.formatted()) sats" }
        return "Custom amount…"
    }

    private func trancheTileBackground(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(selected ? Color.accentColor.opacity(0.15)
                           : Color(.secondarySystemGroupedBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? Color.accentColor : Color(.separator),
                                  lineWidth: selected ? 2 : 1)
            )
    }

    @ViewBuilder
    private var purchaseStateSection: some View {
        switch purchaseState {
        case .idle:
            Section {
                Button {
                    purchase()
                } label: {
                    Label("Top Up \(effectiveAmount) sats", systemImage: "bolt.fill")
                }
                .disabled(effectiveAmount < minimumSats)
            } footer: {
                if minimumSats > 0 {
                    Text("Minimum \(minimumSats) sats.").font(.caption2)
                }
            }

        case .purchasing:
            Section {
                HStack { ProgressView(); Text("Creating invoice…").foregroundStyle(.secondary) }
            }

        case .success(let result):
            invoiceSection(result)
            Section {
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }

        case .error(let message):
            if Self.isProofRequired(message) {
                proofExchangeSection(rawError: message)
            } else {
                errorGuidanceSection(message)
            }
        }
    }

    @ViewBuilder
    private func invoiceSection(_ result: MCPService.PurchaseResult) -> some View {
        Section("Invoice") {
            if let bolt11 = result.lightningInvoice {
                QRCodeView("lightning:\(bolt11)", size: 220)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                Text(bolt11)
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            } else if !result.checkoutLink.isEmpty {
                QRCodeView(result.checkoutLink, size: 220)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }

            if !result.checkoutLink.isEmpty, let url = URL(string: result.checkoutLink) {
                Link(destination: url) {
                    Label("Open Payment Page", systemImage: "arrow.up.right.square").font(.caption)
                }
            }

            if !result.invoiceId.isEmpty {
                Button {
                    checkPayment(invoiceId: result.invoiceId)
                } label: {
                    if case .checking = paymentCheckState {
                        HStack { ProgressView().controlSize(.small); Text("Checking…") }
                    } else {
                        Label("Check Payment", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(paymentCheckState.isChecking)
            }

            if let msg = paymentCheckState.message {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(paymentCheckState.isSettled ? .green : .secondary)
            }
        }
    }

    // MARK: - Error guidance (non-proof failures)

    private struct ErrorGuidance {
        let headline: String
        let icon: String
        let color: Color
        let explanation: String
        let isRetryable: Bool
        let canNotify: Bool
    }

    /// Detect the wheel's proof-required failure.
    static func isProofRequired(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("proof is required") || lower.contains("invalid proof")
    }

    @ViewBuilder
    private func errorGuidanceSection(_ message: String) -> some View {
        let guidance = Self.purchaseErrorGuidance(message, cashierName: cashierName)
        Section {
            Label(guidance.headline, systemImage: guidance.icon)
                .foregroundStyle(guidance.color)
                .font(.subheadline.bold())
            Text(guidance.explanation).font(.caption).foregroundStyle(.secondary)
            if guidance.isRetryable {
                Button("Retry") { purchase() }.buttonStyle(.borderedProminent)
            }
            if guidance.canNotify, let onNotifyCashier {
                Button {
                    dismiss()
                    onNotifyCashier()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "message.fill")
                        Text("Message \(cashierName)")
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            }
        } footer: {
            Text(message).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private static func purchaseErrorGuidance(_ message: String, cashierName: String) -> ErrorGuidance {
        let lower = message.lowercased()

        if (lower.contains("authority") && lower.contains("insufficient")) || lower.contains("certification failed") {
            return ErrorGuidance(
                headline: "Can't Certify Right Now",
                icon: "building.columns.fill",
                color: .orange,
                explanation: "\(cashierName) can't certify this purchase right now — its own certification balance is exhausted. The operator has been notified to top it up. Try again shortly.",
                isRetryable: false,
                canNotify: true
            )
        }
        if lower.contains("btcpay") || lower.contains("payment processor") {
            return ErrorGuidance(
                headline: "Payment Processor Unavailable",
                icon: "bolt.slash.fill",
                color: .red,
                explanation: "\(cashierName)'s payment processor is not responding. Try again later, or let them know.",
                isRetryable: true,
                canNotify: true
            )
        }
        if lower.contains("connection") || lower.contains("timeout") || lower.contains("unreachable") {
            return ErrorGuidance(
                headline: "Connection Failed",
                icon: "wifi.slash",
                color: .red,
                explanation: "Couldn't reach \(cashierName). Check your connection and try again.",
                isRetryable: true,
                canNotify: false
            )
        }
        return ErrorGuidance(
            headline: "Top Up Failed",
            icon: "exclamationmark.triangle.fill",
            color: .red,
            explanation: message,
            isRetryable: true,
            canNotify: true
        )
    }

    // MARK: - Proof exchange

    @ViewBuilder
    private func proofExchangeSection(rawError: String) -> some View {
        Section {
            Label("Identity Proof Required", systemImage: "key.fill")
                .foregroundStyle(.orange)
                .font(.subheadline.bold())

            Text(canAutoSign
                 ? "\(cashierName) needs a fresh Nostr proof that the purchaser owns this npub. The purchaser's nsec is in this device's Keychain, so the App can complete the exchange."
                 : "\(cashierName) needs a fresh Nostr proof that the purchaser owns this npub. Send the challenge, reply in your Nostr client, then verify. Drag this sheet down to use the Messages tab without losing progress.")
                .font(.caption)
                .foregroundStyle(.secondary)

            switch proofState {
            case .idle:
                Button {
                    canAutoSign ? autoCompleteProof() : sendProofChallenge()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: canAutoSign ? "key.fill" : "paperplane.fill")
                        Text(canAutoSign ? "Prove identity with stored nsec" : "Send DM challenge")
                    }
                }
                .buttonStyle(.borderedProminent)

            case .requesting:
                progressRow("Sending challenge DM…")

            case .signingReply:
                progressRow("Signing reply with the purchaser's nsec and publishing to relays…")

            case .awaitingReply:
                Label("Challenge sent. Open your Nostr client (or drag this sheet down and use the Messages tab) to reply to \(cashierName), then tap Verify.", systemImage: "envelope.badge")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !proofRendezvousRelay.isEmpty { rendezvousRelayHint }
                Button {
                    verifyProofAndRetry()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield.fill")
                        Text("I've replied — verify & retry")
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("Cancel proof exchange", role: .cancel) { proofState = .idle }
                    .font(.caption)

            case .verifying:
                progressRow("Verifying proof and retrying…")

            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Try again") {
                    canAutoSign ? autoCompleteProof() : sendProofChallenge()
                }
            }
        } footer: {
            Text(rawError).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func progressRow(_ text: String) -> some View {
        HStack {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary).font(.caption)
        }
    }

    private var rendezvousRelayHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Reply via this relay:").font(.caption2).foregroundStyle(.primary)
            Button {
                UIPasteboard.general.string = proofRendezvousRelay
            } label: {
                HStack(spacing: 4) {
                    Text(proofRendezvousRelay)
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "doc.on.doc").font(.caption2)
                }
                .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            Text("\(cashierName) listens on this relay. Configure your Nostr client to publish there, or the reply will be missed.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Actions

    private func purchase() {
        purchaseState = .purchasing
        Task {
            do {
                guard let endpointURL = URL(string: endpoint) else {
                    throw MCPError.connectionFailed("Invalid endpoint")
                }
                let result = try await mcpService.callPurchaseCredits(
                    endpointURL: endpointURL,
                    amountSats: effectiveAmount,
                    patronNpub: purchaserNpub
                )
                purchaseState = .success(result)
            } catch {
                purchaseState = .error(error.localizedDescription)
            }
        }
    }

    private func sendProofChallenge() {
        guard let endpointURL = URL(string: endpoint) else {
            proofState = .failed("Invalid endpoint URL")
            return
        }
        proofState = .requesting
        Task {
            do {
                let challenge = try await mcpService.callRequestNpubProof(
                    endpointURL: endpointURL,
                    patronNpub: purchaserNpub
                )
                proofRendezvousRelay = challenge.rendezvousRelay
                proofToken = challenge.proofToken
                proofState = .awaitingReply
            } catch {
                proofState = .failed(error.localizedDescription)
            }
        }
    }

    private func verifyProofAndRetry() {
        guard let endpointURL = URL(string: endpoint) else {
            proofState = .failed("Invalid endpoint URL")
            return
        }
        proofState = .verifying
        Task {
            do {
                _ = try await mcpService.callReceiveNpubProof(
                    endpointURL: endpointURL,
                    patronNpub: purchaserNpub,
                    poison: proofToken
                )
                proofState = .idle
                purchase()
            } catch {
                proofState = .failed(error.localizedDescription)
            }
        }
    }

    /// Single-click proof completion — App holds the purchaser's nsec. With
    /// wheel v0.23+ the gate accepts an inline Schnorr proof on the first call
    /// (argsWithProof signs it), so this only needs to retry the purchase.
    private func autoCompleteProof() {
        guard KeychainService.loadNsec(forNpub: purchaserNpub) != nil else {
            proofState = .failed("Purchaser nsec is no longer in Keychain — falling back to manual exchange.")
            return
        }
        proofState = .idle
        purchase()
    }

    private func checkPayment(invoiceId: String) {
        paymentCheckState = .checking
        Task {
            do {
                guard let endpointURL = URL(string: endpoint) else { return }
                // Poll as the PURCHASER (the invoice owner), not the cashier —
                // the invoice and its proof live in the purchaser's ledger.
                let result = try await mcpService.callCheckPayment(
                    endpointURL: endpointURL,
                    invoiceId: invoiceId,
                    npub: purchaserNpub
                )
                if result.status == "Settled" || result.creditsGranted > 0 {
                    paymentCheckState = .settled("Settled! +\(result.creditsGranted) sats credited.")
                    onSettled?()
                } else if result.status == "Expired" {
                    paymentCheckState = .checked("Invoice expired.")
                } else {
                    paymentCheckState = .checked(result.message.isEmpty ? "Not yet paid — try again after paying." : result.message)
                }
            } catch {
                paymentCheckState = .checked("Check failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Beneficiary label

    @ViewBuilder
    private func beneficiaryLabel(_ npub: String) -> some View {
        let hint = beneficiaryDisplayName?.trimmingCharacters(in: .whitespaces)
        if let h = hint, !h.isEmpty {
            Text(h).font(.subheadline.bold()).foregroundStyle(.green)
        } else if let name = NpubNameResolver.displayName(for: npub, in: modelContext) {
            Text(name).font(.subheadline.bold()).foregroundStyle(.green)
        } else {
            Text(String(npub.prefix(16)) + "…")
                .font(.caption.monospaced())
                .foregroundStyle(.green)
        }
    }
}

extension PurchaseCreditsSheet {
    /// An SF Symbol + tint identifying an actor on the tranche pass. Canonical
    /// glyphs mirror `TopologyViewModel`: Operator = server.rack (orange),
    /// Authority = building.columns (blue); Patron = person (green).
    struct ActorBadge {
        let icon: String
        let color: Color
        static let patron = ActorBadge(icon: "person.fill", color: .green)
        static let `operator` = ActorBadge(icon: "server.rack", color: .orange)
        static let authority = ActorBadge(icon: "building.columns", color: .blue)
    }
}

/// A single horizontal line, stroked dashed to read as a ticket perforation.
private struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.width, y: rect.midY))
        return path
    }
}
