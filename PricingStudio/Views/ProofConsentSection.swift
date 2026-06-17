import SwiftUI

/// Reusable human-consent surface for the Secure Courier npub-proof protocol.
///
/// When a wheel tool reports a missing/invalid proof, this renders the remedy
/// path — inline Keychain sign when the nsec is held, else a DM challenge →
/// reply-in-Nostr-client → verify round-trip — instead of dead-ending on an
/// error string. It is the single implementation shared by the Adopt-operator
/// flow and the Pending Adoptions queue; each caller injects its own retry
/// closures (`onAcquire` / `onVerify`) that drive the relevant view model.
///
/// Self-contained (no `Section` wrapper) so it drops into both a `Form` and a
/// plain `VStack`. `phase == nil` shows the remedy (acquire); a non-nil phase
/// shows the in-progress handshake (with Verify on `.awaitingReply`).
struct ProofConsentSection: View {
    /// Human label for the identity whose consent is needed ("Authority", "Operator").
    let kind: String
    let npub: String
    let explanation: String
    let phase: AuthorityCollectionViewModel.ProofPhase?
    let onAcquire: () async -> Void
    let onVerify: () async -> Void

    private var hasNsec: Bool { KeychainService.loadNsec(forNpub: npub) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let phase {
                acquisition(phase)
            } else {
                remedy
            }
        }
    }

    @ViewBuilder
    private var remedy: some View {
        Label("\(kind) proof required", systemImage: "key.fill")
            .foregroundStyle(.orange)
        Text(explanation)
            .font(.caption)
            .foregroundStyle(.secondary)
        Text("npub: \(npub)")
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)

        if hasNsec {
            Button {
                Task { await onAcquire() }
            } label: {
                Label("Sign with Keychain nsec & retry", systemImage: "signature")
            }
        } else {
            Text("The nsec for this npub is not in this device’s Keychain. Use the DM challenge below if you hold the nsec on another Nostr client (e.g. Oxchat).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                Task { await onAcquire() }
            } label: {
                Label("Send DM proof challenge", systemImage: "paperplane.fill")
            }
        }
    }

    @ViewBuilder
    private func acquisition(_ phase: AuthorityCollectionViewModel.ProofPhase) -> some View {
        switch phase {
        case .sending:
            HStack {
                ProgressView()
                Text("Sending proof challenge DM…")
                    .foregroundStyle(.secondary)
            }
        case .awaitingReply:
            Label("DM sent", systemImage: "envelope.badge.fill")
                .foregroundStyle(.blue)
            Text("Open your Nostr client (e.g. Oxchat) and find the DM from this Authority. Reply with any text — your signature on the reply is the proof. Then click Verify below.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                Task { await onVerify() }
            } label: {
                Label("I’ve replied — verify now", systemImage: "checkmark.shield")
            }
        case .verifying:
            HStack {
                ProgressView()
                Text("Verifying reply…")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
