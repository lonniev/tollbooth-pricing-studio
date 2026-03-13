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
    }

    struct TrancheDetail: Identifiable {
        let id: String
        let amountSats: Int
        let remainingSats: Int
        let expiresAt: Date?
        let createdAt: Date?
    }

    // MARK: - Cache

    private var balanceCache: [String: CachedBalance] = [:]
    private static let cacheDuration: TimeInterval = 120

    private struct CachedBalance {
        let balances: [OperatorBalance]
        let fetchedAt: Date
    }

    // MARK: - Services

    private let mcpService = MCPService()
    private let oauthService = OAuthService()

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

        // Fetch each balance sequentially (MainActor-isolated)
        for op in mcpOperators {
            guard let endpointString = op.mcpEndpointURL,
                  let endpointURL = URL(string: endpointString) else { continue }

            let result = await fetchBalance(
                patronNpub: patron.npub,
                operatorNpub: op.npub,
                endpointURL: endpointURL
            )
            if let idx = operatorBalances.firstIndex(where: { $0.id == op.npub }) {
                operatorBalances[idx].balanceState = result
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
        let host = endpointURL.host ?? operatorEndpoint
        let token = try await resolvePatronToken(
            patronNpub: patronNpub,
            operatorHost: host,
            endpointURL: endpointURL
        )
        return try await mcpService.callPurchaseCredits(
            endpointURL: endpointURL,
            bearerToken: token,
            amountSats: amountSats
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
            let host = endpointURL.host ?? operatorNpub
            let token = try await resolvePatronToken(
                patronNpub: patronNpub,
                operatorHost: host,
                endpointURL: endpointURL
            )
            let result = try await mcpService.callCheckBalance(
                endpointURL: endpointURL,
                bearerToken: token
            )
            return .loaded(result)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// Resolve a valid access token for a patron on a specific operator.
    /// 3-tier cascade: cached bundle -> refresh -> full OAuth.
    private func resolvePatronToken(
        patronNpub: String,
        operatorHost: String,
        endpointURL: URL
    ) async throws -> String {
        // 1. Check for cached bundle
        if let bundle = KeychainService.loadTokenBundle(forPatron: patronNpub, operator: operatorHost) {
            if !bundle.isExpired {
                return bundle.accessToken
            }

            // 2. Try refresh
            if bundle.refreshToken != nil {
                do {
                    let refreshed = try await oauthService.refresh(bundle: bundle)
                    try KeychainService.saveTokenBundle(refreshed, forPatron: patronNpub, operator: operatorHost)
                    return refreshed.accessToken
                } catch {
                    TrafficLogger.shared.log(.error, label: "Patron Token Refresh Failed", detail: "\(operatorHost): \(error.localizedDescription)")
                }
            }

            KeychainService.deleteTokenBundle(forPatron: patronNpub, operator: operatorHost)
        }

        // 3. Full OAuth dance
        let bundle = try await oauthService.authenticate(mcpEndpoint: endpointURL)
        try KeychainService.saveTokenBundle(bundle, forPatron: patronNpub, operator: operatorHost)
        return bundle.accessToken
    }
}
