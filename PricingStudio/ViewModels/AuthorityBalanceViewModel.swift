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

    /// Read this Authority's *certification* balance — the api_sats it spends
    /// on `certify_sats` — which lives at its **invoice source**: its parent
    /// Authority for a standard (certified) Authority, or itself for a
    /// penultimate one (which self-funds). `patronNpub` is always this
    /// Authority; only the endpoint differs. This is the balance that runs
    /// dry and refuses certify-up, so it's the one the Top-Off must replenish.
    func loadCertificationBalance(authorityNpub: String, source: InvoiceSource) async {
        guard let endpointString = source.mcpEndpointURL,
              let endpointURL = URL(string: endpointString) else {
            balanceState = .error("No MCP endpoint for \(source.displayName)")
            return
        }

        balanceState = .loading

        do {
            _ = try? await mcpService.callServiceStatus(endpointURL: endpointURL)
            let result = try await mcpService.callCheckBalance(
                endpointURL: endpointURL,
                patronNpub: authorityNpub
            )
            balanceState = .loaded(result)
        } catch {
            balanceState = .error(error.localizedDescription)
        }
    }

    /// Reconcile pending replenishment invoices at the certification source
    /// (parent for a standard Authority, self for a penultimate one).
    func reconcileCertification(
        authorityNpub: String,
        source: InvoiceSource,
        pendingIds: [String]
    ) async {
        guard let endpointString = source.mcpEndpointURL,
              let endpointURL = URL(string: endpointString) else { return }

        isReconciling = true
        reconcileResult = nil

        var settled = 0, expired = 0, stillPending = 0, creditsGained = 0

        for invoiceId in pendingIds {
            do {
                let result = try await mcpService.callCheckPayment(
                    endpointURL: endpointURL,
                    invoiceId: invoiceId,
                    npub: authorityNpub
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
        await loadCertificationBalance(authorityNpub: authorityNpub, source: source)
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
