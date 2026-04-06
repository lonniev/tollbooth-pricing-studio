import SwiftUI
import SwiftData

/// Shows an operator's relationship with its Authority: balance, registration
/// status, and a Top Off action that funds the **operator's** account (not
/// the Authority's own balance).
struct OperatorAuthorityView: View {
    let `operator`: Operator
    let authorityNpub: String

    @Query private var authorities: [Authority]
    @State private var balanceVM = AuthorityBalanceViewModel()
    @State private var showingTopOff = false
    @State private var operatorBalance: Int?
    @State private var isLoadingBalance = false

    private var authority: Authority? {
        authorities.first { $0.npub == authorityNpub }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                authorityCard
                operatorBalanceCard
                topOffSection
            }
            .padding()
        }
        .task { await loadOperatorBalance() }
        .sheet(isPresented: $showingTopOff) {
            if let auth = authority {
                AuthorityTopOffSheet(
                    authorityName: "\(`operator`.displayName) at \(auth.displayName)",
                    authorityNpub: auth.npub,
                    endpoint: auth.mcpEndpointURL ?? "",
                    balanceVM: balanceVM,
                    authority: auth,
                    purchaserNpub: `operator`.npub
                )
            }
        }
    }

    // MARK: - Authority Card

    @ViewBuilder
    private var authorityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "building.columns.fill")
                    .foregroundStyle(.blue)
                Text("Authority")
                    .font(.subheadline.bold())
                Spacer()
            }
            if let auth = authority {
                Text(auth.displayName)
                    .font(.headline)
                Text(auth.npub)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
            } else {
                Text(String(authorityNpub.prefix(20)) + "...")
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Operator Balance at Authority

    @ViewBuilder
    private var operatorBalanceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "creditcard.fill")
                    .foregroundStyle(.orange)
                Text("Operator Balance at Authority")
                    .font(.subheadline.bold())
                Spacer()
                Button {
                    Task { await loadOperatorBalance() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            if isLoadingBalance {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("Loading...").font(.caption).foregroundStyle(.secondary)
                }
            } else if let balance = operatorBalance {
                HStack(spacing: 8) {
                    Text("\(balance) sats")
                        .font(.title2.monospacedDigit().bold())
                        .foregroundStyle(balance < 50 ? .red : .green)

                    if balance == 0 {
                        Label("Empty — patron purchases will fail", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if balance < 50 {
                        Label("Low — top off soon", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Text("This is \(`operator`.displayName)'s tax account at the Authority. " +
                     "The Authority deducts a 2% fee (min 10 sats) from this balance " +
                     "each time a patron purchases credits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Tap refresh to check balance")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Top Off

    @ViewBuilder
    private var topOffSection: some View {
        if authority?.mcpEndpointURL != nil {
            Button {
                showingTopOff = true
            } label: {
                Label("Top Off Operator Account", systemImage: "bolt.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.large)
        } else {
            Label("Authority has no MCP endpoint configured", systemImage: "link.badge.plus")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Balance Loading

    private func loadOperatorBalance() async {
        guard let auth = authority,
              let endpointString = auth.mcpEndpointURL,
              let endpointURL = URL(string: endpointString) else { return }

        isLoadingBalance = true
        let mcpService = MCPService()

        do {
            let result = try await mcpService.callCheckBalance(
                endpointURL: endpointURL,
                patronNpub: `operator`.npub
            )
            operatorBalance = result.balanceApiSats
        } catch {
            // Leave nil — will show "tap refresh"
        }

        isLoadingBalance = false
    }
}
