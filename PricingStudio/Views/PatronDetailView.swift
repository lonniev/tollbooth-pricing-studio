import SwiftUI
import SwiftData
import CoreImage
import UIKit

struct PatronDetailView: View {
    let patron: Patron
    @Bindable var accountVM: PatronAccountViewModel
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
            await accountVM.loadBalances(for: patron, operators: operators)
        }
        .refreshable {
            await accountVM.forceRefresh(for: patron, operators: operators)
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

    // MARK: - Authenticated Patron Balances

    @ViewBuilder
    private var operatorAccountsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Authenticated Patron at")
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
                            patronNpub: patron.npub,
                            accountVM: accountVM
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
    let patronNpub: String
    let accountVM: PatronAccountViewModel
    @State private var isExpanded = false
    @State private var showingTopOff = false

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
                patronNpub: patronNpub,
                operatorName: balance.operatorName,
                endpoint: balance.endpoint,
                accountVM: accountVM
            )
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
            Text("\(result.balanceApiSats) sats")
                .font(.subheadline.monospacedDigit())
                .foregroundColor(result.balanceApiSats > 0 ? .primary : .red)
        case .error(let msg):
            Label("Error", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .help(msg)
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
            }
            GridRow {
                Text("Consumed").font(.caption).foregroundStyle(.secondary)
                Text("\(result.totalConsumed) sats").font(.caption.monospacedDigit())
            }
            GridRow {
                Text("Expired").font(.caption).foregroundStyle(.secondary)
                Text("\(result.totalExpired) sats").font(.caption.monospacedDigit())
            }
            GridRow {
                Text("Active Tranches").font(.caption).foregroundStyle(.secondary)
                Text("\(result.activeTranches)").font(.caption.monospacedDigit())
            }

            if result.expiringWithin24h > 0 {
                GridRow {
                    Text("Expiring <24h").font(.caption).foregroundStyle(.orange)
                    Text("\(result.expiringWithin24h) sats").font(.caption.monospacedDigit()).foregroundStyle(.orange)
                }
            }

            if let next = result.nextExpiration {
                GridRow {
                    Text("Next Expiry").font(.caption).foregroundStyle(.secondary)
                    Text(next.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption.monospacedDigit())
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

        Button {
            showingTopOff = true
        } label: {
            Label("Top Off", systemImage: "plus.circle.fill")
                .font(.caption.bold())
        }
        .buttonStyle(.borderedProminent)
        .tint(result.balanceApiSats < 100 || result.expiringWithin24h > 0 ? .orange : .accentColor)
        .controlSize(.small)
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

private struct TopOffSheet: View {
    let patronNpub: String
    let operatorName: String
    let endpoint: String
    let accountVM: PatronAccountViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedAmount = 500
    @State private var customAmount = ""
    @State private var purchaseState: PurchaseState = .idle

    private let presets = [100, 500, 1000, 5000]

    private enum PurchaseState {
        case idle
        case purchasing
        case success(MCPService.PurchaseResult)
        case error(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Operator") {
                    Text(operatorName)
                        .font(.headline)
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
                            qrCodeImage(for: bolt11)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }

                        if !result.checkoutLink.isEmpty, let url = URL(string: result.checkoutLink) {
                            Link(destination: url) {
                                Label("Open in Wallet", systemImage: "arrow.up.right.square")
                            }
                        }

                        if let bolt11 = result.lightningInvoice {
                            Text(bolt11)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }
                    }

                    Section {
                        Button("Done") {
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                case .error(let message):
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)

                        Button("Retry") {
                            purchase()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Top Off Credits")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
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

    @ViewBuilder
    private func qrCodeImage(for string: String) -> some View {
        if let image = generateQRCode(from: string) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 200, height: 200)
        }
    }

    private func generateQRCode(from string: String) -> UIImage? {
        guard let data = string.data(using: .ascii),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        return UIImage(ciImage: scaled)
    }
}
