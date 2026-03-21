import Foundation

@MainActor
@Observable
final class AuthorityBalanceViewModel {

    enum BalanceState {
        case idle
        case loading
        case loaded(PatronAccountViewModel.BalanceResult)
        case error(String)
    }

    private(set) var balanceState: BalanceState = .idle
    private(set) var isReconciling = false
    var reconcileResult: PatronAccountViewModel.ReconcileResult?

    private let mcpService = MCPService()
    private let oauthService = OAuthService()

    func loadBalance(for authority: Authority) async {
        guard let endpointString = authority.mcpEndpointURL,
              let endpointURL = URL(string: endpointString) else {
            balanceState = .error("No MCP endpoint")
            return
        }

        balanceState = .loading

        do {
            let host = endpointURL.host ?? authority.npub
            let token = try await resolveToken(host: host, endpointURL: endpointURL)
            let result = try await mcpService.callCheckBalance(
                endpointURL: endpointURL,
                bearerToken: token
            )
            balanceState = .loaded(result)
        } catch {
            balanceState = .error(error.localizedDescription)
        }
    }

    func reconcile(authority: Authority, pendingIds: [String]) async {
        guard let endpointString = authority.mcpEndpointURL,
              let endpointURL = URL(string: endpointString) else { return }

        isReconciling = true
        reconcileResult = nil

        do {
            let host = endpointURL.host ?? authority.npub
            let token = try await resolveToken(host: host, endpointURL: endpointURL)

            var settled = 0, expired = 0, stillPending = 0, creditsGained = 0

            for invoiceId in pendingIds {
                do {
                    let result = try await mcpService.callCheckPayment(
                        endpointURL: endpointURL,
                        bearerToken: token,
                        invoiceId: invoiceId
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

            reconcileResult = PatronAccountViewModel.ReconcileResult(
                settled: settled,
                expired: expired,
                stillPending: stillPending,
                creditsGained: creditsGained
            )
        } catch {
            reconcileResult = PatronAccountViewModel.ReconcileResult(
                settled: 0, expired: 0, stillPending: pendingIds.count, creditsGained: 0
            )
        }

        isReconciling = false
        await loadBalance(for: authority)
    }

    // MARK: - Private

    private func resolveToken(host: String, endpointURL: URL) async throws -> String {
        if let bundle = KeychainService.loadTokenBundle(forPatron: "authority", operator: host) {
            if !bundle.isExpired {
                return bundle.accessToken
            }
            if bundle.refreshToken != nil {
                do {
                    let refreshed = try await oauthService.refresh(bundle: bundle)
                    try KeychainService.saveTokenBundle(refreshed, forPatron: "authority", operator: host)
                    return refreshed.accessToken
                } catch { /* fall through */ }
            }
            KeychainService.deleteTokenBundle(forPatron: "authority", operator: host)
        }
        let bundle = try await oauthService.authenticate(mcpEndpoint: endpointURL)
        try KeychainService.saveTokenBundle(bundle, forPatron: "authority", operator: host)
        return bundle.accessToken
    }
}
