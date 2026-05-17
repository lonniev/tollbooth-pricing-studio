import SwiftUI
import SwiftData
import CoreImage
import UIKit
import WebKit

struct PatronDetailView: View {
    let patron: Patron
    @Bindable var accountVM: PatronAccountViewModel
    var onOpenMessages: ((_ operatorNpub: String) -> Void)?
    var onRequestCourier: ((CourierParams) -> Void)?
    @Query(sort: \Operator.addedAt) private var operators: [Operator]

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                headerSection
                operatorAccountsSection
            }
            .padding()
        }
        .navigationTitle(patron.displayName)
        .task(id: patron.npub) {
            await accountVM.loadBalances(for: patron, sources: operators.map(\.asInvoiceSource))
        }
        .refreshable {
            // Detach so SwiftUI body re-renders during the in-flight
            // refresh can't cancel the underlying mcpService calls.
            // Extract value-typed parameters first to avoid capturing
            // the Patron @Model into the detached closure.
            let patronNpub = patron.npub
            let sourceList = operators.map(\.asInvoiceSource)
            await Task.detached(priority: .userInitiated) {
                await accountVM.forceRefresh(forNpub: patronNpub, sources: sourceList)
            }.value
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)

            Text(patron.displayName)
                .font(.title2.bold())

            if let nip05 = patron.nip05 {
                Text(nip05)
                    .font(.subheadline)
                    .foregroundColor(.accentColor)
                    .textSelection(.enabled)
            }

            Text(patron.npub)
                .font(.caption)
                .monospaced()
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("Added \(patron.addedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if KeychainService.loadNsec(forNpub: patron.npub) != nil {
                Label("nsec stored in Keychain", systemImage: "checkmark.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }

    // MARK: - Patron Credit Balances

    @ViewBuilder
    private var operatorAccountsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Credit Balances")
                .font(.headline)

            if accountVM.operatorBalances.isEmpty {
                ContentUnavailableView(
                    "No Operator Connections",
                    systemImage: "server.rack",
                    description: Text("Add operators with MCP endpoints to view balances.")
                )
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(accountVM.operatorBalances) { balance in
                        OperatorBalanceCard(
                            balance: balance,
                            patron: patron,
                            operator: operators.first(where: { $0.npub == balance.id }),
                            accountVM: accountVM,
                            onOpenMessages: onOpenMessages,
                            onRequestCourier: onRequestCourier,
                            onRefreshNeeded: {
                                Task {
                                    await accountVM.forceRefresh(for: patron, sources: operators.map(\.asInvoiceSource))
                                }
                            }
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Operator Balance Card

private struct OperatorBalanceCard: View {
    let balance: PatronAccountViewModel.OperatorBalance
    let patron: Patron
    let `operator`: Operator?
    let accountVM: PatronAccountViewModel
    var onOpenMessages: ((_ operatorNpub: String) -> Void)?
    var onRequestCourier: ((CourierParams) -> Void)?
    var onRefreshNeeded: (() -> Void)?
    @State private var isExpanded = false
    @State private var showingTopOff = false
    @State private var showingInfographic = false
    @State private var isReconciling = false
    @State private var reconcileResult: PatronAccountViewModel.ReconcileResult?
    @State private var patronOnboarding: MCPService.PatronOnboardingStatus?
    @State private var loadingOnboarding = false
    @State private var showingErrorDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(balance.operatorName)
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        Text(balance.endpoint)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    Spacer()

                    balanceBadge

                    if case .loaded = balance.balanceState {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
            }
            .buttonStyle(.plain)

            if isExpanded, case .loaded(let result) = balance.balanceState {
                expandedDetail(result)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .sheet(isPresented: $showingTopOff) {
            TopOffSheet(
                patronNpub: patron.npub,
                operatorName: balance.operatorName,
                endpoint: balance.endpoint,
                accountVM: accountVM,
                onNotifyOperator: onOpenMessages.map { callback in
                    { callback(balance.id) }
                },
                onSettled: { onRefreshNeeded?() },
                beneficiaryDisplayName: patron.displayName,
                cashierNpub: balance.id
            )
        }
        .sheet(isPresented: $showingInfographic) {
            InfographicSheet(
                patronName: patron.displayName,
                operatorName: balance.operatorName,
                operatorNpub: balance.id,
                accountVM: accountVM,
                serviceEndpoint: balance.endpoint,
                patronNpub: patron.npub
            )
        }
        .task {
            // Auto-check patron credential status when card appears
            if patronOnboarding == nil {
                await loadPatronOnboardingStatus()
            }
        }
    }

    @ViewBuilder
    private var balanceBadge: some View {
        switch balance.balanceState {
        case .loading:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("Brr\u{2026}").font(.caption).foregroundStyle(.secondary)
            }
        case .loaded(let result):
            HStack(spacing: 6) {
                Text("\(result.balanceApiSats) sats")
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(result.balanceApiSats > 0 ? .green : .red)
                if result.pendingInvoiceCount > 0 {
                    Text("\(result.pendingInvoiceCount) pending")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
        case .error(let msg):
            Button {
                showingErrorDetail = true
            } label: {
                Label("Error", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingErrorDetail) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Balance Check Failed", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(.red)
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding()
                .frame(maxWidth: 320)
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    @ViewBuilder
    private func expandedDetail(_ result: PatronAccountViewModel.BalanceResult) -> some View {
        Divider()
            .padding(.bottom, 8)

        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("Deposited").font(.caption).foregroundStyle(.secondary)
                Text("\(result.totalDeposited) sats").font(.caption.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            GridRow {
                Text("Consumed").font(.caption).foregroundStyle(.secondary)
                Text("\(result.totalConsumed) sats").font(.caption.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            GridRow {
                Text("Expired").font(.caption).foregroundStyle(.secondary)
                Text("\(result.totalExpired) sats").font(.caption.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            GridRow {
                Text("Active Tranches").font(.caption).foregroundStyle(.secondary)
                Text("\(result.activeTranches)").font(.caption.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if result.expiringWithin24h > 0 {
                GridRow {
                    Text("Expiring <24h").font(.caption).foregroundStyle(.orange)
                    Text("\(result.expiringWithin24h) sats").font(.caption.monospacedDigit()).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            if let next = result.nextExpiration {
                GridRow {
                    Text("Next Expiry").font(.caption).foregroundStyle(.secondary)
                    Text(next.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption.monospacedDigit())
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }

        if !result.tranches.isEmpty {
            Divider()
                .padding(.vertical, 4)

            ForEach(result.tranches) { tranche in
                HStack(alignment: .firstTextBaseline) {
                    Text("\(tranche.remainingSats) sats")
                        .font(.caption.monospacedDigit().bold())
                    Text("of \(tranche.amountSats)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    trancheExpirationLabel(tranche.expiresAt)
                }
            }
        }

        Divider()
            .padding(.vertical, 4)

        HStack(spacing: 12) {
            Button {
                showingTopOff = true
            } label: {
                Label("Top Off", systemImage: "plus.circle.fill")
                    .font(.caption.bold())
            }
            .buttonStyle(.borderedProminent)
            .tint(result.balanceApiSats < 100 || result.expiringWithin24h > 0 ? .orange : Color.accentColor)
            .controlSize(.small)

            Button {
                showingInfographic = true
                if let op = self.operator {
                    Task {
                        await accountVM.fetchInfographic(for: patron, operator: op)
                    }
                }
            } label: {
                Label("Statement", systemImage: "chart.bar.doc.horizontal")
                    .font(.caption.bold())
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if !result.pendingInvoiceIds.isEmpty {
                Button {
                    Task { await reconcilePending(result) }
                } label: {
                    if isReconciling {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label("Reconcile", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption.bold())
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isReconciling)
            }
        }

        if let rr = reconcileResult {
            HStack(spacing: 8) {
                if rr.settled > 0 {
                    Label("\(rr.settled) settled (+\(rr.creditsGained) sats)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                if rr.expired > 0 {
                    Label("\(rr.expired) expired", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
                if rr.stillPending > 0 {
                    Label("\(rr.stillPending) still pending", systemImage: "clock")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption2)
            .padding(.top, 4)
        }

        // Credential status
        credentialSection
    }

    // MARK: - Patron Credential Section

    @ViewBuilder
    private var credentialSection: some View {
        Divider()
            .padding(.vertical, 4)

        let service = patronOnboarding?.credentialService ?? ""
        let credType = patronOnboarding?.credentialType ?? ""

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if credType == "none_or_dynamic" {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.teal)
                } else {
                    Image(systemName: patronOnboarding?.ready == true ? "checkmark.shield.fill" : "shield.slash")
                        .foregroundStyle(patronOnboarding?.ready == true ? .green : .secondary)
                }
                Text("Patron Secrets")
                    .font(.caption.bold())
                Spacer()

                if loadingOnboarding {
                    ProgressView().controlSize(.mini)
                }
            }

            if credType == "none_or_dynamic" {
                Label("No patron credentials needed", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.teal)
            } else if let status = patronOnboarding {
                let configuredSecrets = status.configured
                let missingSecrets = status.missing

                ForEach(configuredSecrets, id: \.field) { field in
                    HStack(spacing: 4) {
                        Image(systemName: field.lifecycle == "dynamic" ? "arrow.triangle.2.circlepath.circle.fill" : "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                        Text(fieldLabel(field.field))
                            .font(.caption2)
                        if field.lifecycle == "dynamic" {
                            Text("auto-renewed")
                                .font(.system(size: 9))
                                .foregroundStyle(.teal)
                        }
                    }
                }

                ForEach(missingSecrets, id: \.field) { field in
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Text(fieldLabel(field.field))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            HStack(spacing: 8) {
                if patronOnboarding == nil && !loadingOnboarding {
                    Button {
                        Task { await loadPatronOnboardingStatus() }
                    } label: {
                        Label("Check", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                let hasMissing = !(patronOnboarding?.missing.isEmpty ?? true)
                if hasMissing && credType != "none_or_dynamic",
                   let endpointString = self.operator?.mcpEndpointURL,
                   let endpointURL = URL(string: endpointString) {
                    Button {
                        onRequestCourier?(CourierParams(
                            operatorName: balance.operatorName,
                            operatorNpub: balance.id,
                            endpointURL: endpointURL,
                            credentialService: patronOnboarding?.credentialService ?? "",
                            missingSecrets: (patronOnboarding?.missing ?? []).map { fieldLabel($0.field) },
                            greeting: patronOnboarding?.credentialGreeting ?? "",
                            senderNpub: patron.npub
                        ))
                    } label: {
                        Label("Deliver", systemImage: "lock.shield")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.orange)
                }

                Button(role: .destructive) {
                    Task { await forgetPatronCredentials(service: service) }
                } label: {
                    Label("Forget", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func fieldLabel(_ field: String) -> String {
        field.replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private func loadPatronOnboardingStatus() async {
        guard let endpointString = self.operator?.mcpEndpointURL,
              let endpointURL = URL(string: endpointString) else { return }
        loadingOnboarding = true
        do {
            patronOnboarding = try await MCPService().callGetPatronOnboardingStatus(
                endpointURL: endpointURL,
                patronNpub: patron.npub
            )
        } catch {
            // Silently handle — the section just won't show details
        }
        loadingOnboarding = false
    }

    private func forgetPatronCredentials(service: String) async {
        guard let endpointString = self.operator?.mcpEndpointURL,
              let endpointURL = URL(string: endpointString) else { return }
        do {
            try await MCPService().callForgetCredentials(
                endpointURL: endpointURL,
                service: service,
                npub: patron.npub
            )
        } catch {
            // Log but don't block — local cleanup proceeds
        }
        // Also clear local ncred if any
        KeychainService.deleteNcred(forPatron: patron.npub, service: service, operator: balance.id)
        // Refresh onboarding status to show missing credentials + Deliver button
        await loadPatronOnboardingStatus()
    }

    private func reconcilePending(_ result: PatronAccountViewModel.BalanceResult) async {
        isReconciling = true
        reconcileResult = nil
        do {
            reconcileResult = try await accountVM.reconcilePendingInvoices(
                patronNpub: patron.npub,
                operatorEndpoint: balance.endpoint,
                pendingInvoiceIds: result.pendingInvoiceIds
            )
        } catch {
            reconcileResult = PatronAccountViewModel.ReconcileResult(
                settled: 0, expired: 0, stillPending: result.pendingInvoiceIds.count, creditsGained: 0
            )
        }
        isReconciling = false
    }

    @ViewBuilder
    private func trancheExpirationLabel(_ expiresAt: Date?) -> some View {
        if let exp = expiresAt {
            let isUrgent = exp.timeIntervalSinceNow < 24 * 3600
            Text("Expires \(exp.formatted(.dateTime.month(.abbreviated).day().year()))")
                .font(.caption2)
                .foregroundStyle(isUrgent ? (exp.timeIntervalSinceNow < 0 ? .red : .orange) : .secondary)
                .fontWeight(isUrgent ? .semibold : .regular)
        } else {
            Text("No expiration")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Top Off Sheet

struct TopOffSheet: View {
    let patronNpub: String
    let operatorName: String
    let endpoint: String
    let accountVM: PatronAccountViewModel
    var onNotifyOperator: (() -> Void)?
    var onSettled: (() -> Void)?
    /// Caller-supplied display name for the beneficiary npub, when the parent
    /// view already knows it (e.g., presenting this sheet from a specific
    /// Patron's page). Bypasses the SwiftData walk for the obvious case.
    var beneficiaryDisplayName: String? = nil
    /// The npub of the cashier (operator or authority) — the receiver of the
    /// proof-reply DM in the auto-sign path. When empty, the auto-sign branch
    /// is disabled and the sheet falls back to the human-in-the-loop flow.
    var cashierNpub: String = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var selectedAmount = 500
    @State private var customAmount = ""
    @State private var purchaseState: PurchaseState = .idle
    @State private var paymentCheckState: PaymentCheckState = .idle
    @State private var proofState: ProofExchangeState = .idle

    private let presets = [100, 500, 1000, 5000]
    private let mcpService = MCPService()

    private enum PurchaseState {
        case idle
        case purchasing
        case success(MCPService.PurchaseResult)
        case error(String)
    }

    /// Inline proof-exchange state. Two paths share the state machine:
    /// (a) auto-sign — when the App holds the purchaser's nsec, it sends
    /// the poison reply DM itself and proceeds straight to verifying; the
    /// initial click is the human's consent.
    /// (b) human-in-the-loop — when no nsec is in Keychain, the App stops
    /// at `awaitingReply` and the user replies via their own Nostr client.
    private enum ProofExchangeState: Equatable {
        case idle           // never started yet for this error
        case requesting     // calling request_npub_proof
        case signingReply   // auto-sign: composing+sending poison reply DM
        case awaitingReply  // HITL: DM sent, waiting for human to reply
        case verifying      // calling receive_npub_proof
        case failed(String)
    }

    /// Whether the App can complete the proof without further human action —
    /// requires the purchaser's nsec in Keychain AND a known cashier npub.
    private var canAutoSign: Bool {
        !cashierNpub.isEmpty
            && KeychainService.loadNsec(forNpub: patronNpub) != nil
    }

    private enum PaymentCheckState {
        case idle
        case checking
        case settled(String)
        case checked(String)

        var isChecking: Bool {
            if case .checking = self { return true }
            return false
        }

        var isSettled: Bool {
            if case .settled = self { return true }
            return false
        }

        var message: String? {
            switch self {
            case .settled(let msg), .checked(let msg): return msg
            default: return nil
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Beneficiary") {
                        beneficiaryLabel(patronNpub)
                    }
                    LabeledContent("Cashier") {
                        Text(operatorName)
                            .font(.subheadline.bold())
                    }
                } header: {
                    Text("Purchase Credits")
                } footer: {
                    Text("Credits go to the beneficiary's balance at \(operatorName). Anyone can pay the Lightning invoice — the funds source doesn't matter.")
                        .font(.caption2)
                }

                Section("Amount (sats)") {
                    HStack(spacing: 8) {
                        ForEach(presets, id: \.self) { amount in
                            Button("\(amount)") {
                                selectedAmount = amount
                                customAmount = ""
                            }
                            .buttonStyle(.bordered)
                            .tint(selectedAmount == amount && customAmount.isEmpty ? .accentColor : .secondary)
                            .controlSize(.small)
                        }
                    }

                    TextField("Custom amount", text: $customAmount)
                        .keyboardType(.numberPad)
                        .onChange(of: customAmount) { _, newValue in
                            if let val = Int(newValue), val > 0 {
                                selectedAmount = val
                            }
                        }
                }

                switch purchaseState {
                case .idle:
                    Section {
                        Button {
                            purchase()
                        } label: {
                            Label("Purchase \(effectiveAmount) sats", systemImage: "bolt.fill")
                        }
                        .disabled(effectiveAmount < 110)
                    } footer: {
                        Text("Minimum purchase: 110 sats (100 net + 10 Authority fee)")
                            .font(.caption2)
                    }

                case .purchasing:
                    Section {
                        HStack {
                            ProgressView()
                            Text("Creating invoice...")
                                .foregroundStyle(.secondary)
                        }
                    }

                case .success(let result):
                    Section("Invoice") {
                        if let bolt11 = result.lightningInvoice {
                            qrCodeImage(for: "lightning:\(bolt11)")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        } else if !result.checkoutLink.isEmpty {
                            qrCodeImage(for: result.checkoutLink)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }

                        if !result.checkoutLink.isEmpty, let url = URL(string: result.checkoutLink) {
                            Link(destination: url) {
                                Label("Open Payment Page", systemImage: "arrow.up.right.square")
                            }
                        }

                        if let bolt11 = result.lightningInvoice {
                            Text(bolt11)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }

                        if !result.invoiceId.isEmpty {
                            LabeledContent("Invoice ID") {
                                Text(result.invoiceId)
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                            }

                            Button {
                                checkPayment(invoiceId: result.invoiceId)
                            } label: {
                                if case .checking = paymentCheckState {
                                    HStack { ProgressView().controlSize(.small); Text("Checking...") }
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

                    Section {
                        Button("Done") {
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                case .error(let message):
                    if Self.isProofRequired(message) {
                        proofExchangeSection(rawError: message)
                    } else {
                        Section {
                            let guidance = Self.purchaseErrorGuidance(message, operatorName: operatorName)
                            Label(guidance.headline, systemImage: guidance.icon)
                                .foregroundStyle(guidance.color)
                                .font(.subheadline.bold())

                            Text(guidance.explanation)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if guidance.isRetryable {
                                Button("Retry") {
                                    purchase()
                                }
                                .buttonStyle(.borderedProminent)
                            }

                            if guidance.canNotify, let onNotifyOperator {
                                Button {
                                    dismiss()
                                    onNotifyOperator()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "message.fill")
                                        Text("Message \(operatorName)")
                                    }
                                    .font(.caption)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.blue)
                            }
                        } footer: {
                            Text(message)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .navigationTitle("Purchase Credits")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(paymentCheckState.isSettled ? "Done" : "Cancel") { dismiss() }
                }
            }
        }
        // Detents + background-interaction let the user drag the sheet
        // down to a compact pill and reach the Messages tab to reply to
        // the proof-challenge DM without losing the in-flight proof
        // exchange or the staged amount selection.
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationContentInteraction(.scrolls)
    }

    private struct ErrorGuidance {
        let headline: String
        let icon: String
        let color: Color
        let explanation: String
        let isRetryable: Bool
        let canNotify: Bool
    }

    /// Detect the wheel's proof-required failure. Returned by paid tools
    /// whose npub argument has no fresh cached proof token.
    static func isProofRequired(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("proof is required") || lower.contains("invalid proof")
    }

    private static func purchaseErrorGuidance(_ message: String, operatorName: String) -> ErrorGuidance {
        let lower = message.lowercased()

        if lower.contains("authority") && lower.contains("insufficient") || lower.contains("certification failed") {
            return ErrorGuidance(
                headline: "Operator Payment Not Ready",
                icon: "building.columns.fill",
                color: .orange,
                explanation: "\(operatorName)'s payment authority doesn't have enough funds to certify this purchase. This isn't something you can fix — the operator needs to fund their Authority account.",
                isRetryable: false,
                canNotify: true
            )
        }

        if lower.contains("btcpay") || lower.contains("payment processor") {
            return ErrorGuidance(
                headline: "Payment Processor Unavailable",
                icon: "bolt.slash.fill",
                color: .red,
                explanation: "\(operatorName)'s payment processor is not responding. Try again later, or let the operator know.",
                isRetryable: true,
                canNotify: true
            )
        }

        if lower.contains("connection") || lower.contains("timeout") || lower.contains("unreachable") {
            return ErrorGuidance(
                headline: "Connection Failed",
                icon: "wifi.slash",
                color: .red,
                explanation: "Couldn't reach \(operatorName). Check your connection and try again.",
                isRetryable: true,
                canNotify: false
            )
        }

        // Generic fallback
        return ErrorGuidance(
            headline: "Purchase Failed",
            icon: "exclamationmark.triangle.fill",
            color: .red,
            explanation: message,
            isRetryable: true,
            canNotify: true
        )
    }

    private var effectiveAmount: Int {
        if let val = Int(customAmount), val > 0 { return val }
        return selectedAmount
    }

    private func purchase() {
        purchaseState = .purchasing
        Task {
            do {
                let result = try await accountVM.purchaseCredits(
                    patronNpub: patronNpub,
                    operatorEndpoint: endpoint,
                    amountSats: effectiveAmount
                )
                purchaseState = .success(result)
            } catch {
                purchaseState = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Proof Exchange (human-in-the-loop)

    @ViewBuilder
    private func proofExchangeSection(rawError: String) -> some View {
        Section {
            Label("Identity Proof Required", systemImage: "key.fill")
                .foregroundStyle(.orange)
                .font(.subheadline.bold())

            if canAutoSign {
                Text("\(operatorName) needs a fresh Nostr proof that you own this npub. Your nsec is in this device's Keychain, so the App can complete the exchange for you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(operatorName) needs a fresh Nostr proof that you own this npub. You'll send a challenge DM, reply in your Nostr client, then verify. You can drag this sheet down to use the Messages tab without losing progress.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            switch proofState {
            case .idle:
                if canAutoSign {
                    Button {
                        autoCompleteProof()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "key.fill")
                            Text("Prove identity with stored nsec")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        sendProofChallenge()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "paperplane.fill")
                            Text("Send DM challenge")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

            case .requesting:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Sending challenge DM…").foregroundStyle(.secondary).font(.caption)
                }

            case .signingReply:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Signing reply with your nsec and publishing to relays…")
                        .foregroundStyle(.secondary).font(.caption)
                }

            case .awaitingReply:
                Label("Challenge sent. Open your Nostr client (or drag this sheet down and use the Messages tab) to reply to \(operatorName), then tap Verify.", systemImage: "envelope.badge")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    verifyProofAndRetry()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield.fill")
                        Text("I've replied — verify & retry")
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("Cancel proof exchange", role: .cancel) {
                    proofState = .idle
                }
                .font(.caption)

            case .verifying:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Verifying proof and retrying purchase…").foregroundStyle(.secondary).font(.caption)
                }

            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Try again") {
                    if canAutoSign { autoCompleteProof() } else { sendProofChallenge() }
                }
            }
        } footer: {
            Text(rawError)
                .font(.caption2)
                .foregroundStyle(.tertiary)
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
                _ = try await mcpService.callRequestNpubProof(
                    endpointURL: endpointURL,
                    patronNpub: patronNpub
                )
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
                // callReceiveNpubProof persists the proof_token to Keychain
                // for the (patron, endpoint host) pair, so the subsequent
                // purchase() call picks it up via argsWithProof.
                _ = try await mcpService.callReceiveNpubProof(
                    endpointURL: endpointURL,
                    patronNpub: patronNpub
                )
                proofState = .idle
                purchase()
            } catch {
                proofState = .failed(error.localizedDescription)
            }
        }
    }

    /// Single-click proof completion when the App holds the purchaser's
    /// nsec. With wheel v0.23 the proof gate accepts an inline Schnorr
    /// proof on the very first call — no relay round-trip needed.
    /// argsWithProof inside MCPService picks the Schnorr tactic
    /// automatically when the nsec is in Keychain, so the only thing
    /// this needs to do is retry purchase().
    private func autoCompleteProof() {
        guard KeychainService.loadNsec(forNpub: patronNpub) != nil else {
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
                let result = try await accountVM.reconcilePendingInvoices(
                    patronNpub: patronNpub,
                    operatorEndpoint: endpoint,
                    pendingInvoiceIds: [invoiceId]
                )
                if result.settled > 0 {
                    paymentCheckState = .settled("Settled! +\(result.creditsGained) sats credited.")
                    onSettled?()
                } else if result.expired > 0 {
                    paymentCheckState = .checked("Invoice expired.")
                } else {
                    paymentCheckState = .checked("Not yet paid — try again after paying.")
                }
            } catch {
                paymentCheckState = .checked("Check failed: \(error.localizedDescription)")
            }
        }
    }

    @ViewBuilder
    private func qrCodeImage(for string: String) -> some View {
        QRCodeView(string)
    }

    /// Beneficiary label — prefers a caller-supplied display name (the
    /// "obvious choice" from the parent view's context), falls back to the
    /// SwiftData walk across Patron / Operator / Authority / Contact, and
    /// finally renders a truncated raw npub.
    @ViewBuilder
    private func beneficiaryLabel(_ npub: String) -> some View {
        let hint = beneficiaryDisplayName?.trimmingCharacters(in: .whitespaces)
        if let h = hint, !h.isEmpty {
            Text(h)
                .font(.subheadline.bold())
                .foregroundStyle(.green)
        } else if let name = NpubNameResolver.displayName(for: npub, in: modelContext) {
            Text(name)
                .font(.subheadline.bold())
                .foregroundStyle(.green)
        } else {
            Text(String(npub.prefix(16)) + "…")
                .font(.caption.monospaced())
                .foregroundStyle(.green)
        }
    }
}

// MARK: - Infographic Sheet

private struct InfographicSheet: View {
    let patronName: String
    let operatorName: String
    let operatorNpub: String
    let accountVM: PatronAccountViewModel
    var serviceEndpoint: String = ""
    var patronNpub: String = ""
    @Environment(\.dismiss) private var dismiss
    @State private var showingShareSheet = false
    @State private var statement: MCPService.AccountStatementResult?
    @State private var statementError: String?
    @State private var loadingStatement = false

    /// The current SVG string (if loaded).
    private var svgString: String? {
        if case .loaded(.svg(let s)) = accountVM.infographicStates[operatorNpub] { return s }
        return nil
    }

    /// The current PNG data (if loaded).
    private var pngData: Data? {
        if case .loaded(.png(let d)) = accountVM.infographicStates[operatorNpub] { return d }
        return nil
    }

    var body: some View {
        NavigationStack {
            Group {
                switch accountVM.infographicStates[operatorNpub] ?? .idle {
                case .idle, .loading:
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Generating statement infographic...")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .loaded(let content):
                    switch content {
                    case .svg(let svgString):
                        SVGWebView(svgContent: svgString)
                            .ignoresSafeArea(edges: .bottom)
                    case .png(let data):
                        if let uiImage = UIImage(data: data) {
                            ScrollView {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFit()
                                    .padding()
                            }
                        } else {
                            ContentUnavailableView(
                                "Invalid Image",
                                systemImage: "photo.badge.exclamationmark",
                                description: Text("Could not decode the infographic image.")
                            )
                        }
                    }

                case .error(let message):
                    // Infographic unavailable — fall back to the free JSON
                    // statement rendered as a paper-printout receipt.
                    if let statement = statement {
                        VStack(spacing: 0) {
                            fallbackBanner(message)
                            AccountStatementPaperView(
                                patronName: patronName,
                                patronNpub: patronNpub,
                                operatorName: operatorName,
                                statement: statement
                            )
                        }
                    } else if loadingStatement {
                        VStack(spacing: 16) {
                            ProgressView().controlSize(.large)
                            Text("Loading free statement\u{2026}").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let err = statementError {
                        ContentUnavailableView(
                            "Statement Unavailable",
                            systemImage: "chart.bar.xaxis.ascending.badge.clock",
                            description: Text("\(message)\n\nFree statement also failed:\n\(err)")
                        )
                    } else {
                        ContentUnavailableView(
                            "Statement Unavailable",
                            systemImage: "chart.bar.xaxis.ascending.badge.clock",
                            description: Text(message)
                        )
                    }
                }
            }
            .navigationTitle("\(patronName) with \(operatorName) Statement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if svgString != nil || pngData != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingShareSheet = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                if let svg = svgString {
                    let filename = "\(operatorName)-statement.svg"
                    let svgData = Data(svg.utf8)
                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                    let _ = try? svgData.write(to: tempURL)
                    ShareSheet(items: [tempURL])
                } else if let data = pngData {
                    if let image = UIImage(data: data) {
                        ShareSheet(items: [image])
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            // If infographic already errored, fetch free statement immediately
            if case .error = accountVM.infographicStates[operatorNpub] {
                await fetchFreeStatement()
            }
        }
        .onChange(of: accountVM.infographicStates[operatorNpub]?.isError) { _, isErr in
            if isErr == true {
                Task { await fetchFreeStatement() }
            }
        }
    }

    private func fetchFreeStatement() async {
        guard !serviceEndpoint.isEmpty, !patronNpub.isEmpty else { return }
        guard let url = URL(string: serviceEndpoint) else { return }
        loadingStatement = true
        statementError = nil
        do {
            statement = try await MCPService().callAccountStatement(
                endpointURL: url,
                patronNpub: patronNpub
            )
        } catch {
            statementError = error.localizedDescription
        }
        loadingStatement = false
    }

    /// Yellow banner above the paper-printout explaining why we fell back.
    @ViewBuilder
    private func fallbackBanner(_ infographicError: String) -> some View {
        let reason: String = {
            if infographicError.contains("proof is required") || infographicError.contains("invalid proof") {
                return "Infographic needs an npub proof — request_npub_proof + receive_npub_proof, then retry. Free statement below."
            }
            if infographicError.contains("Insufficient") {
                return "Infographic requires credits — showing the free statement below."
            }
            if infographicError.contains("TBD") {
                return "Infographic not yet priced — showing the free statement below."
            }
            return "Infographic unavailable — showing the free statement below."
        }()
        Label(reason, systemImage: "doc.text")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.12))
    }
}

/// UIActivityViewController wrapper for share sheet.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - SVG Web View

private struct SVGWebView: UIViewRepresentable {
    let svgContent: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = true
        webView.backgroundColor = UIColor(red: 0.051, green: 0.067, blue: 0.09, alpha: 1) // #0d1117
        webView.scrollView.backgroundColor = webView.backgroundColor
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=3.0">
        <meta name="color-scheme" content="dark">
        <style>
            html, body {
                margin: 0; padding: 16px;
                display: flex; justify-content: center; align-items: flex-start;
                background: #0d1117;
                color-scheme: dark;
                -webkit-user-select: none;
            }
            svg { max-width: 100%; height: auto; }
        </style>
        </head>
        <body>\(svgContent)</body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }
}

// MARK: - Account Statement View (reusable for any patron-at-service)

/// Shows balance, tranches with expiration, Top Off, Statement infographic,
/// and Reconcile. Works for Patron→Operator, Operator→Authority, or
/// Authority→Upstream.
struct AccountStatementView: View {
    let patronNpub: String
    let serviceName: String
    let serviceNpub: String
    let serviceEndpoint: String
    @Bindable var accountVM: PatronAccountViewModel
    var onRequestCourier: ((CourierParams) -> Void)?
    /// The entity's own MCP endpoint (for credential management). Distinct from
    /// serviceEndpoint which is where credits are held (e.g., the Authority).
    var ownEndpoint: String?

    @State private var balanceState: PatronAccountViewModel.BalanceState = .loading
    @State private var showingTopOff = false
    @State private var showingInfographic = false
    @State private var isReconciling = false
    @State private var reconcileResult: PatronAccountViewModel.ReconcileResult?
    @State private var showingForgetConfirm = false
    @State private var forgetState: ForgetState = .idle
    @State private var onboardingStatus: MCPService.OnboardingStatus?
    @State private var loadingOnboarding = false

    private enum ForgetState { case idle, forgetting, done(String), error(String) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                balanceCard
                if onRequestCourier != nil, ownEndpoint != nil {
                    credentialSection
                }
            }
            .padding()
        }
        .task(id: "\(patronNpub):\(serviceNpub)") {
            balanceState = .loading
            onboardingStatus = nil
            forgetState = .idle
            await loadBalance()
        }
        .refreshable { await loadBalance() }
        .sheet(isPresented: $showingTopOff) {
            TopOffSheet(
                patronNpub: patronNpub,
                operatorName: serviceName,
                endpoint: serviceEndpoint,
                accountVM: accountVM,
                onNotifyOperator: nil,
                onSettled: { Task { await loadBalance() } },
                cashierNpub: serviceNpub
            )
        }
        .sheet(isPresented: $showingInfographic) {
            InfographicSheet(
                patronName: String(patronNpub.prefix(16)) + "\u{2026}",
                operatorName: serviceName,
                operatorNpub: serviceNpub,
                accountVM: accountVM,
                serviceEndpoint: serviceEndpoint,
                patronNpub: patronNpub
            )
        }
    }

    @ViewBuilder
    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Account at \(serviceName)")
                        .font(.subheadline.bold())
                    Text(serviceEndpoint)
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
                balanceBadge
            }
            .padding(12)

            switch balanceState {
            case .loading:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading account\u{2026}").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            case .loaded(let result):
                expandedDetail(result).padding(.horizontal, 12).padding(.bottom, 12)
            case .error(let msg):
                VStack(alignment: .leading, spacing: 8) {
                    Label("Balance unavailable", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.bold()).foregroundStyle(.red)
                    Text(msg).font(.caption2).foregroundStyle(.secondary)
                    Button("Retry") { Task { await loadBalance() } }
                        .font(.caption).buttonStyle(.bordered).controlSize(.mini)
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var balanceBadge: some View {
        switch balanceState {
        case .loading:
            ProgressView().controlSize(.small)
        case .loaded(let result):
            HStack(spacing: 6) {
                Text("\(result.balanceApiSats) sats")
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(result.balanceApiSats > 0 ? .green : .red)
                if result.pendingInvoiceCount > 0 {
                    Text("\(result.pendingInvoiceCount) pending")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func expandedDetail(_ result: PatronAccountViewModel.BalanceResult) -> some View {
        Divider().padding(.bottom, 8)

        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("Deposited").font(.caption).foregroundStyle(.secondary)
                Text("\(result.totalDeposited) sats").font(.caption.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            GridRow {
                Text("Consumed").font(.caption).foregroundStyle(.secondary)
                Text("\(result.totalConsumed) sats").font(.caption.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if result.totalExpired > 0 {
                GridRow {
                    Text("Expired").font(.caption).foregroundStyle(.red)
                    Text("\(result.totalExpired) sats").font(.caption.monospacedDigit()).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            GridRow {
                Text("Active Tranches").font(.caption).foregroundStyle(.secondary)
                Text("\(result.activeTranches)").font(.caption.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if result.expiringWithin24h > 0 {
                GridRow {
                    Text("Expiring <24h").font(.caption).foregroundStyle(.orange)
                    Text("\(result.expiringWithin24h) sats").font(.caption.monospacedDigit()).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            if let next = result.nextExpiration {
                GridRow {
                    Text("Next Expiry").font(.caption).foregroundStyle(.secondary)
                    Text(next.formatted(date: .abbreviated, time: .shortened)).font(.caption.monospacedDigit())
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }

        if !result.tranches.isEmpty {
            Divider().padding(.vertical, 4)
            ForEach(result.tranches) { tranche in
                HStack(alignment: .firstTextBaseline) {
                    Text("\(tranche.remainingSats) sats")
                        .font(.caption.monospacedDigit().bold())
                        .foregroundColor(tranche.remainingSats > 0 ? .primary : .red)
                    Text("of \(tranche.amountSats)")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    if let exp = tranche.expiresAt {
                        let remaining = exp.timeIntervalSinceNow
                        if remaining <= 0 {
                            Text("Expired").font(.caption2).foregroundStyle(.red)
                        } else if remaining < 86400 {
                            Text("\(Int(remaining / 3600))h left").font(.caption2).foregroundStyle(.orange)
                        } else {
                            Text("\(Int(remaining / 86400))d left").font(.caption2).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No expiration").font(.caption2).foregroundStyle(.green)
                    }
                }
            }
        }

        Divider().padding(.vertical, 4)

        HStack(spacing: 12) {
            Button { showingTopOff = true } label: {
                Label("Top Off", systemImage: "plus.circle.fill").font(.caption.bold())
            }
            .buttonStyle(.borderedProminent)
            .tint(result.balanceApiSats < 100 || result.expiringWithin24h > 0 ? .orange : Color.accentColor)
            .controlSize(.small)

            Button {
                showingInfographic = true
                Task {
                    await accountVM.fetchInfographic(
                        patronNpub: patronNpub,
                        serviceNpub: serviceNpub,
                        endpoint: serviceEndpoint
                    )
                }
            } label: {
                Label("Statement", systemImage: "chart.bar.doc.horizontal").font(.caption.bold())
            }
            .buttonStyle(.bordered).controlSize(.small)

            if !result.pendingInvoiceIds.isEmpty {
                Button {
                    Task { await reconcilePending(result) }
                } label: {
                    if isReconciling {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label("Reconcile", systemImage: "arrow.triangle.2.circlepath").font(.caption.bold())
                    }
                }
                .buttonStyle(.bordered).controlSize(.small).disabled(isReconciling)
            }
        }

        if let rr = reconcileResult {
            HStack(spacing: 8) {
                if rr.settled > 0 {
                    Label("\(rr.settled) settled (+\(rr.creditsGained) sats)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                if rr.expired > 0 {
                    Label("\(rr.expired) expired", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                }
                if rr.stillPending > 0 {
                    Label("\(rr.stillPending) still pending", systemImage: "clock").foregroundStyle(.orange)
                }
            }
            .font(.caption2).padding(.top, 4)
        }
    }

    private func loadBalance() async {
        balanceState = .loading
        guard let url = URL(string: serviceEndpoint) else {
            balanceState = .error("Invalid endpoint URL")
            return
        }
        do {
            let result = try await MCPService().callCheckBalance(endpointURL: url, patronNpub: patronNpub)
            balanceState = .loaded(result)
        } catch {
            balanceState = .error(error.localizedDescription)
        }
    }

    private func reconcilePending(_ result: PatronAccountViewModel.BalanceResult) async {
        isReconciling = true
        reconcileResult = try? await accountVM.reconcilePendingInvoices(
            patronNpub: patronNpub,
            operatorEndpoint: serviceEndpoint,
            pendingInvoiceIds: result.pendingInvoiceIds
        )
        await loadBalance()
        isReconciling = false
    }

    // MARK: - Credential Management

    @ViewBuilder
    private var credentialSection: some View {
        Divider()
            .padding(.vertical, 4)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: onboardingStatus?.ready == true ? "checkmark.shield.fill" : "shield.slash")
                    .foregroundStyle(onboardingStatus?.ready == true ? .green : .secondary)
                Text("Operator Secrets")
                    .font(.caption.bold())
                Spacer()
                if loadingOnboarding {
                    ProgressView().controlSize(.mini)
                }
            }

            if let status = onboardingStatus {
                ForEach(status.configured, id: \.field) { field in
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                        Text(fieldLabel(field.field))
                            .font(.caption2)
                    }
                }

                ForEach(status.missing, id: \.field) { field in
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Text(fieldLabel(field.field))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            HStack(spacing: 8) {
                if onboardingStatus == nil && !loadingOnboarding {
                    Button {
                        Task { await loadOnboardingStatus() }
                    } label: {
                        Label("Check", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                let hasMissing = !(onboardingStatus?.missing.isEmpty ?? true)
                if hasMissing,
                   let ep = ownEndpoint, let url = URL(string: ep) {
                    Button {
                        let missing = onboardingStatus?.missing.map(\.field) ?? []
                        let svc = onboardingStatus?.credentialService ?? "operator"
                        onRequestCourier?(CourierParams(
                            operatorName: serviceName,
                            operatorNpub: serviceNpub,
                            endpointURL: url,
                            credentialService: svc,
                            missingSecrets: missing,
                            greeting: onboardingStatus?.credentialGreeting ?? "",
                            senderNpub: patronNpub
                        ))
                    } label: {
                        Label("Deliver", systemImage: "lock.shield")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.orange)
                }

                if onboardingStatus != nil {
                    Button(role: .destructive) {
                        showingForgetConfirm = true
                    } label: {
                        Label("Forget", systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            switch forgetState {
            case .idle: EmptyView()
            case .forgetting:
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Forgetting\u{2026}").font(.caption2).foregroundStyle(.secondary)
                }
            case .done(let msg):
                Label(msg, systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
            case .error(let msg):
                Label(msg, systemImage: "xmark.circle.fill").font(.caption2).foregroundStyle(.red)
            }
        }
        .task {
            if onboardingStatus == nil { await loadOnboardingStatus() }
        }
        .confirmationDialog("Forget Credentials", isPresented: $showingForgetConfirm, titleVisibility: .visible) {
            Button("Forget credentials for \(serviceName)", role: .destructive) {
                Task { await forgetCredentials() }
            }
        } message: {
            Text("This removes the vaulted credentials. Re-deliver via Secure Courier to use this service again.")
        }
    }

    private func loadOnboardingStatus() async {
        guard let ep = ownEndpoint, let url = URL(string: ep) else { return }
        loadingOnboarding = true
        do {
            onboardingStatus = try await MCPService().callGetOnboardingStatus(endpointURL: url)
        } catch {
            // Non-fatal — credential section just won't show field details
        }
        loadingOnboarding = false
    }

    private func forgetCredentials() async {
        forgetState = .forgetting
        let svc = onboardingStatus?.credentialService ?? "operator"
        guard let ep = ownEndpoint, let url = URL(string: ep) else {
            forgetState = .error("Invalid endpoint")
            return
        }
        do {
            _ = try await MCPService().callForgetCredentials(endpointURL: url, service: svc, npub: patronNpub)
            forgetState = .done("Credentials forgotten. Re-deliver via Secure Courier.")
            await loadOnboardingStatus()
        } catch {
            forgetState = .error(error.localizedDescription)
        }
    }

    private func fieldLabel(_ field: String) -> String {
        field.replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
