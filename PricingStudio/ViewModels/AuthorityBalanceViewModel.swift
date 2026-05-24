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
            // Session-priming register (Authority registering its own npub
            // against itself) is only attempted when this device actually
            // holds the Authority's nsec. Without the nsec, the wheel
            // (0.26.0+) rejects with authority_consent_required and the
            // traffic log fills with noisy errors for Authorities we don't
            // sign for. check_balance handles its own proof handshake
            // independently, so the register call is purely a warmup.
            if KeychainService.loadNsec(forNpub: authority.npub) != nil {
                _ = try? await mcpService.callRegisterOperator(
                    endpointURL: endpointURL,
                    operatorNpub: authority.npub,
                    authorityNpub: authority.npub
                )
            }
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
