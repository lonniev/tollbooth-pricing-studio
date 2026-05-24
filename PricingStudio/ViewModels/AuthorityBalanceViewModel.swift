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

    func loadBalance(for authority: Authority) async {
        guard let endpointString = authority.mcpEndpointURL,
              let endpointURL = URL(string: endpointString) else {
            balanceState = .error("No MCP endpoint")
            return
        }

        balanceState = .loading

        do {
            // Wake the MCP if it's serverless-cold. service_status is a
            // free, read-only tool that exists on every Tollbooth MCP and
            // requires no proof — the right shape for a session warmup.
            // (Previously this used register_operator, which is a write
            // tool whose 0.26.0+ authority_proof requirement filled the
            // traffic log with noise for Authorities we don't sign for.)
            _ = try? await mcpService.callServiceStatus(endpointURL: endpointURL)
            let result = try await mcpService.callCheckBalance(
                endpointURL: endpointURL,
                patronNpub: authority.npub
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

        var settled = 0, expired = 0, stillPending = 0, creditsGained = 0

        for invoiceId in pendingIds {
            do {
                let result = try await mcpService.callCheckPayment(
                    endpointURL: endpointURL,
                    invoiceId: invoiceId,
                    npub: authority.npub
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

        isReconciling = false
        await loadBalance(for: authority)
    }

}
