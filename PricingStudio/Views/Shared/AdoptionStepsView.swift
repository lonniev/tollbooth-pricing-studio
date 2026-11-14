import SwiftUI

/// The two steps of an adoption, each with its own state, so nobody stares at
/// one spinner wondering what it waits for. The Operator asks; the Authority
/// approves, which also sets up the Operator's database.
struct AdoptionStepsView: View {
    enum StepState: Equatable {
        case pending
        case running
        case done
        case failed
    }

    let ask: StepState
    /// `nil` when this flow does not approve: the Authority's owner decides later.
    let approve: StepState?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(symbol: "paperplane", title: "Ask", state: ask)
            if let approve {
                row(symbol: "checkmark.seal", title: "Approve · sets up its database", state: approve)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("adoptionSteps")
    }

    private func row(symbol: String, title: String, state: StepState) -> some View {
        HStack(spacing: 10) {
            marker(for: state)
                .frame(width: 22)
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            Text(title)
                .foregroundStyle(state == .pending ? .secondary : .primary)
        }
    }

    @ViewBuilder
    private func marker(for state: StepState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running:
            ProgressView()
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}
