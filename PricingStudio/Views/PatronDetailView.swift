import SwiftUI
import SwiftData

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
        .task {
            await accountVM.loadBalances(for: patron, operators: operators)
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

    // MARK: - Operator Accounts

    @ViewBuilder
    private var operatorAccountsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Operator Accounts")
                .font(.headline)

            if accountVM.operatorBalances.isEmpty {
                ContentUnavailableView(
                    "No Operator Accounts",
                    systemImage: "server.rack",
                    description: Text("Add operators with MCP endpoints to view balances.")
                )
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(accountVM.operatorBalances) { balance in
                        OperatorBalanceCard(balance: balance)
                    }
                }
            }
        }
    }
}

// MARK: - Operator Balance Card

private struct OperatorBalanceCard: View {
    let balance: PatronAccountViewModel.OperatorBalance
    @State private var isExpanded = false

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
    }

    @ViewBuilder
    private var balanceBadge: some View {
        switch balance.balanceState {
        case .loading:
            ProgressView()
                .controlSize(.small)
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
    }
}
