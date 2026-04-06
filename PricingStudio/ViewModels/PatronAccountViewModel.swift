import Foundation
import SwiftData

@MainActor
@Observable
final class PatronAccountViewModel {

    // MARK: - State

    enum State: Sendable {
        case idle
        case loading
        case loaded
        case error(String)
    }

    private(set) var state: State = .idle
    var operatorBalances: [OperatorBalance] = []

    // MARK: - Per-Operator Balance

    struct OperatorBalance: Identifiable {
        let id: String  // operator npub
        let operatorName: String
        let endpoint: String
        var balanceState: BalanceState
    }

    enum BalanceState {
        case loading
        case loaded(BalanceResult)
        case error(String)
    }

    struct BalanceResult {
        let balanceApiSats: Int
        let totalDeposited: Int
        let totalConsumed: Int
        let totalExpired: Int
        let activeTranches: Int
        let expiringWithin24h: Int
        let nextExpiration: Date?
        var tranches: [TrancheDetail] = []
        var pendingInvoiceCount: Int = 0
        var pendingInvoiceIds: [String] = []
        var invoiceSummary: InvoiceSummary?
    }

    struct InvoiceSummary {
        let totalInvoices: Int
        let settledCount: Int
        let pendingCount: Int
        let totalRealSats: Int
        let totalApiSatsCredited: Int
    }

    struct TrancheDetail: Identifiable {
        let id: String
        let amountSats: Int
        let remainingSats: Int
        let expiresAt: Date?
        let createdAt: Date?
    }

    // MARK: - Invoice History

    enum InvoiceHistoryState {
        case idle
        case loading
        case loaded([MCPService.InvoiceLineItem])
        case error(String)
    }

    /// Per-operator invoice history, keyed by operator npub
    var invoiceHistoryStates: [String: InvoiceHistoryState] = [:]

    func fetchInvoiceHistory(for patron: Patron, operator op: Operator) async {
        guard let endpointString = op.mcpEndpointURL,
              let endpointURL = URL(string: endpointString) else { return }

        invoiceHistoryStates[op.npub] = .loading

        do {
            let result = try await mcpService.callAccountStatement(
                endpointURL: endpointURL,
                patronNpub: patron.npub
            )
            invoiceHistoryStates[op.npub] = .loaded(result.invoiceItems)
        } catch {
            invoiceHistoryStates[op.npub] = .error(error.localizedDescription)
        }
    }

    func loadAllInvoiceHistory(for patron: Patron, operators: [Operator]) async {
        let mcpOperators = operators.filter { $0.mcpEndpointURL != nil }
        // Extract sendable values before entering task group
        let patronNpub = patron.npub
        let opInfos: [(npub: String, endpoint: String)] = mcpOperators.compactMap { op in
            guard let endpoint = op.mcpEndpointURL else { return nil }
            return (op.npub, endpoint)
        }
        await withTaskGroup(of: (String, [MCPService.InvoiceLineItem]).self) { group in
            for info in opInfos {
                group.addTask {
                    guard let endpointURL = URL(string: info.endpoint) else {
                        return (info.npub, [])
                    }
                    do {
                        let result = try await self.mcpService.callAccountStatement(
                            endpointURL: endpointURL,
                            patronNpub: patronNpub
                        )
                        return (info.npub, result.invoiceItems)
                    } catch {
                        return (info.npub, [])
                    }
                }
            }
            for await (npub, items) in group {
                invoiceHistoryStates[npub] = items.isEmpty ? .loaded([]) : .loaded(items)
            }
        }
    }

    // MARK: - Cache

    private var balanceCache: [String: CachedBalance] = [:]
    private static let cacheDuration: TimeInterval = 120

    private struct CachedBalance {
        let balances: [OperatorBalance]
        let fetchedAt: Date
    }

    // MARK: - Infographic

    enum InfographicState {
        case idle
        case loading
        case loaded(InfographicContent)
        case error(String)
    }

    enum InfographicContent {
        case svg(String)
        case png(Data)
    }

    /// Per-operator infographic state, keyed by operator npub
    var infographicStates: [String: InfographicState] = [:]

    func fetchInfographic(for patron: Patron, operator op: Operator) async {
        guard let endpointString = op.mcpEndpointURL,
              let endpointURL = URL(string: endpointString) else { return }

        infographicStates[op.npub] = .loading

        do {
            let result = try await mcpService.callAccountStatementInfographic(
                endpointURL: endpointURL,
                patronNpub: patron.npub
            )

            if let svg = result.svgContent {
                infographicStates[op.npub] = .loaded(.svg(svg))
            } else if let pngBase64 = result.pngBase64,
                      let data = Data(base64Encoded: pngBase64) {
                infographicStates[op.npub] = .loaded(.png(data))
            } else {
                infographicStates[op.npub] = .error("No image data in response")
            }
        } catch {
            infographicStates[op.npub] = .error(error.localizedDescription)
        }
    }

    // MARK: - Services

    private let mcpService = MCPService()

    // MARK: - Load

    func loadBalances(for patron: Patron, operators: [Operator]) async {
        let mcpOperators = operators.filter { $0.mcpEndpointURL != nil }

        guard !mcpOperators.isEmpty else {
            operatorBalances = []
            state = .loaded
            return
        }

        // Check cache
        if let cached = balanceCache[patron.npub],
           Date().timeIntervalSince(cached.fetchedAt) < Self.cacheDuration {
            operatorBalances = cached.balances
            state = .loaded
            return
        }

        // Initialize with loading states
        operatorBalances = mcpOperators.map { op in
            OperatorBalance(
                id: op.npub,
                operatorName: op.displayName,
                endpoint: op.mcpEndpointURL ?? "",
                balanceState: .loading
            )
        }
        state = .loading

        // Fetch all balances in parallel
        let patronNpub = patron.npub
        let opEndpoints: [(npub: String, endpoint: String)] = mcpOperators.compactMap { op in
            guard let ep = op.mcpEndpointURL else { return nil }
            return (op.npub, ep)
        }
        await withTaskGroup(of: (String, BalanceState).self) { group in
            for info in opEndpoints {
                group.addTask {
                    guard let endpointURL = URL(string: info.endpoint) else {
                        return (info.npub, .error("Invalid endpoint URL"))
                    }
                    let result = await self.fetchBalance(
                        patronNpub: patronNpub,
                        operatorNpub: info.npub,
                        endpointURL: endpointURL
                    )
                    return (info.npub, result)
                }
            }
            for await (npub, result) in group {
                if let idx = operatorBalances.firstIndex(where: { $0.id == npub }) {
                    operatorBalances[idx].balanceState = result
                }
            }
        }

        balanceCache[patron.npub] = CachedBalance(
            balances: operatorBalances,
            fetchedAt: Date()
        )
        state = .loaded
    }

    func forceRefresh(for patron: Patron, operators: [Operator]) async {
        balanceCache.removeValue(forKey: patron.npub)
        await loadBalances(for: patron, operators: operators)
    }

    func purchaseCredits(
        patronNpub: String,
        operatorEndpoint: String,
        amountSats: Int
    ) async throws -> MCPService.PurchaseResult {
        guard let endpointURL = URL(string: operatorEndpoint) else {
            throw MCPError.connectionFailed("Invalid endpoint URL")
        }
        return try await mcpService.callPurchaseCredits(
            endpointURL: endpointURL,
            amountSats: amountSats,
            patronNpub: patronNpub
        )
    }

    // MARK: - Invoice Reconciliation

    struct ReconcileResult {
        let settled: Int
        let expired: Int
        let stillPending: Int
        let creditsGained: Int
    }

    func reconcilePendingInvoices(
        patronNpub: String,
        operatorEndpoint: String,
        pendingInvoiceIds: [String]
    ) async throws -> ReconcileResult {
        guard let endpointURL = URL(string: operatorEndpoint) else {
            throw MCPError.connectionFailed("Invalid endpoint URL")
        }

        var settled = 0, expired = 0, stillPending = 0, creditsGained = 0

        for invoiceId in pendingInvoiceIds {
            do {
                let result = try await mcpService.callCheckPayment(
                    endpointURL: endpointURL,
                    invoiceId: invoiceId,
                    npub: patronNpub
                )
                switch result.status {
                case "Settled":
                    settled += 1
                    creditsGained += result.creditsGranted
                case "Expired", "Invalid":
                    expired += 1
                default:
                    stillPending += 1
                }
            } catch {
                stillPending += 1
            }
        }

        // Invalidate cache so next balance load picks up changes
        balanceCache.removeAll()

        return ReconcileResult(
            settled: settled,
            expired: expired,
            stillPending: stillPending,
            creditsGained: creditsGained
        )
    }

    func reset() {
        state = .idle
        operatorBalances = []
    }

    // MARK: - Private

    private func fetchBalance(
        patronNpub: String,
        operatorNpub: String,
        endpointURL: URL
    ) async -> BalanceState {
        do {
            let result = try await mcpService.callCheckBalance(
                endpointURL: endpointURL,
                patronNpub: patronNpub
            )
            return .loaded(result)
        } catch {
            return .error(error.localizedDescription)
        }
    }

}
