import SwiftUI

/// Load state for an actor's single balance. Shared across the Patron/Operator/
/// Authority surfaces so one card can render them all. Wraps the canonical
/// ``PatronAccountViewModel/BalanceResult``.
enum BalanceLoadState {
    case idle
    case loading
    case loaded(PatronAccountViewModel.BalanceResult)
    case error(String)
}

/// The one balance every actor has: the **api_sats it holds at its parent's
/// store**, funded by Lightning (`purchase_credits`) and spent as the
/// certification fee (`certify_sats`) each time it sells. The economy is
/// self-similar — a Patron at its Operator, an Operator at its Authority, and a
/// (standard) Authority at its parent Authority all hold exactly this — so they
/// all render with this one card.
///
/// A penultimate Authority (parent is Prime, which runs no store) self-funds and
/// holds no upstream balance; pass `selfFunded: true` to render that state.
///
/// Presentation only and view-model-agnostic: the host supplies the load state
/// and reconcile status, and wires the action closures to its own data source
/// and purchase sheet.
struct ParentAccountCard: View {
    /// Display name of the parent whose store holds this balance.
    let parentDisplayName: String
    let balance: BalanceLoadState

    /// Penultimate Authority: no parent store, so no upstream balance.
    var selfFunded: Bool = false
    /// Qualitative description of what drains the balance. NEVER a specific
    /// percentage — the fee comes from the operator's dynamic pricing model.
    var feeExplanation: String = ""
    /// "Top up" for an on-ramp, "Replenish" when restoring upstream capacity.
    var topUpLabel: String = "Top up"

    var isReconciling: Bool = false
    var reconcileResult: PatronAccountViewModel.ReconcileResult? = nil

    var onTopUp: () -> Void = {}
    var onReconcile: () -> Void = {}
    var onRefresh: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if selfFunded {
                selfFundedBody
            } else {
                header
                balanceBody
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Header (active account)

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Label("Your account at \(parentDisplayName)", systemImage: "creditcard.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                if !feeExplanation.isEmpty {
                    Text(feeExplanation)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button(action: onTopUp) {
                Label(topUpLabel, systemImage: "bolt.fill").font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .tint(.green)
            Button(action: onRefresh) {
                Label("Refresh", systemImage: "arrow.clockwise").font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }

    // MARK: - Self-funded (penultimate Authority)

    private var selfFundedBody: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Trust anchor — self-funded")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text("No upstream balance required")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    // MARK: - Balance body

    @ViewBuilder
    private var balanceBody: some View {
        switch balance {
        case .idle:
            Text("Tap refresh to check balance")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .onAppear(perform: onRefresh)
        case .loading:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
        case .loaded(let result):
            loadedBody(result)
        case .error:
            errorBody
        }
    }

    @ViewBuilder
    private func loadedBody(_ result: PatronAccountViewModel.BalanceResult) -> some View {
        let isUnknown = result.balanceApiSats == 0 && result.totalDeposited == 0
        let balanceColor: Color = isUnknown
            ? .secondary
            : (result.balanceApiSats < 50 ? .red : .primary)

        HStack(spacing: 16) {
            Text(isUnknown ? "N/A" : "\(result.balanceApiSats) api_sats")
                .font(.subheadline.monospacedDigit().bold())
                .foregroundStyle(balanceColor)

            if result.pendingInvoiceCount > 0 {
                Text("\(result.pendingInvoiceCount) pending")
                    .font(.caption2.bold())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.2), in: Capsule())
                    .foregroundStyle(.orange)
            }

            Spacer()

            if !result.pendingInvoiceIds.isEmpty {
                Button(action: onReconcile) {
                    if isReconciling {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label("Reconcile", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption2)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(isReconciling)
            }
        }

        if !isUnknown && result.balanceApiSats < 50 {
            Label("Low balance — sales may fail to certify until you top up",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        }

        if let rr = reconcileResult {
            HStack(spacing: 6) {
                if rr.settled > 0 {
                    Label("+\(rr.creditsGained)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                if rr.expired > 0 {
                    Label("\(rr.expired) expired", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
            .font(.caption2)
        }
    }

    private var errorBody: some View {
        HStack(spacing: 8) {
            Text("??? api_sats")
                .font(.subheadline.monospacedDigit().bold())
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onRefresh) {
                Label("Retry", systemImage: "arrow.clockwise").font(.caption2)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }
}
