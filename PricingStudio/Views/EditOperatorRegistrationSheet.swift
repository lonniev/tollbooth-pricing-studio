import SwiftUI
import SwiftData

/// Allows editing an Operator's community registry entry (service URL, display name)
/// via the Authority's update_operator tool.
struct EditOperatorRegistrationSheet: View {
    let operatorTarget: any PricingTarget
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Authority.addedAt) private var authorities: [Authority]
    @State private var serviceURL: String = ""
    @State private var displayName: String = ""
    @State private var status: UpdateStatus = .idle

    enum UpdateStatus: Equatable {
        case idle
        case updating
        case success(String)
        case failed(String)
        /// Wheel returned `authority_consent_required` — the call needs a
        /// fresh Schnorr identity proof signed by the Authority's npub.
        case needsAuthorityProof(npub: String)
        /// Wheel returned `proof_required` / `proof_invalid` / `proof_refresh_needed`
        /// on the operator-side gate.
        case needsOperatorProof(npub: String)
        /// Studio is acquiring a proof via the request/receive_npub_proof
        /// Secure Courier handshake against the Authority's MCP.
        case acquiringProof(npub: String, phase: AuthorityCollectionViewModel.ProofPhase)

        // Explicit Equatable — Swift would synthesize, but `ProofPhase`
        // lives in another file and indexers occasionally trip over the
        // cross-file synthesis check. Inline is unambiguous.
        static func == (lhs: UpdateStatus, rhs: UpdateStatus) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.updating, .updating): return true
            case (.success(let a), .success(let b)): return a == b
            case (.failed(let a), .failed(let b)): return a == b
            case (.needsAuthorityProof(let a), .needsAuthorityProof(let b)): return a == b
            case (.needsOperatorProof(let a), .needsOperatorProof(let b)): return a == b
            case (.acquiringProof(let an, let ap), .acquiringProof(let bn, let bp)):
                return an == bn && ap == bp
            default: return false
            }
        }
    }

    private var isSuccess: Bool {
        if case .success = status { return true }
        return false
    }

    /// True while the update or a downstream proof-acquisition call is
    /// mid-flight. The Update button is disabled in any of these states.
    private var isUpdateInFlight: Bool {
        switch status {
        case .updating, .acquiringProof:
            return true
        default:
            return false
        }
    }

    /// Resolve the Authority that sponsors this Operator.
    private var sponsoringAuthority: Authority? {
        guard let op = operatorTarget as? Operator,
              let authNpub = op.authorityNpub else { return nil }
        return authorities.first { $0.npub == authNpub }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(operatorTarget.displayName)
                            .font(.headline)
                        Text(operatorTarget.npub)
                            .font(.caption)
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Operator")
                }

                Section {
                    TextField("MCP Endpoint URL", text: $serviceURL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .monospaced()
                        .font(.caption)
                } header: {
                    Text("Service URL")
                } footer: {
                    Text("The public MCP endpoint for this operator (e.g. https://my-service.fastmcp.app/mcp)")
                }

                Section {
                    TextField("Display Name", text: $displayName)
                } header: {
                    Text("Display Name")
                } footer: {
                    Text("Human-readable name shown in the community registry")
                }

                if let auth = sponsoringAuthority {
                    Section {
                        HStack {
                            Text(auth.displayName)
                                .font(.subheadline)
                            Spacer()
                            Text(String(auth.npub.prefix(20)) + "...")
                                .font(.caption)
                                .monospaced()
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Sponsoring Authority")
                    }
                } else {
                    Section {
                        Text("No sponsoring Authority found. The operator must be registered with an Authority before updating.")
                            .foregroundStyle(.secondary)
                    }
                }

                if case .updating = status {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Updating registration...")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if case .success(let msg) = status {
                    Section {
                        Label("Updated", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.green)
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if case .failed(let error) = status {
                    Section {
                        Label("Update failed", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // --- Proof acquisition remedy --------------------------------
                if case .needsAuthorityProof(let npub) = status {
                    proofRemedySection(
                        kind: "Authority",
                        npub: npub,
                        explanation: "The Authority's wheel needs cryptographic proof that you hold the Authority's nsec before it will modify this operator's registry entry."
                    )
                }

                if case .needsOperatorProof(let npub) = status {
                    proofRemedySection(
                        kind: "Operator",
                        npub: npub,
                        explanation: "The Authority's wheel needs cryptographic proof that you hold the operator's nsec."
                    )
                }

                if case .acquiringProof(let npub, let phase) = status {
                    proofAcquisitionInProgressSection(npub: npub, phase: phase)
                }
            }
            .navigationTitle(isSuccess ? "Registration Updated" : "Edit Registration")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isSuccess {
                        Button("Done") { dismiss() }
                    } else {
                        Button("Cancel") { dismiss() }
                    }
                }
                if !isSuccess {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Update") {
                            Task { await performUpdate() }
                        }
                        .disabled(
                            sponsoringAuthority == nil ||
                            (serviceURL.isEmpty && displayName.isEmpty) ||
                            isUpdateInFlight
                        )
                    }
                }
            }
            .onAppear {
                serviceURL = operatorTarget.mcpEndpointURL ?? ""
                displayName = operatorTarget.displayName
            }
        }
    }

    private func performUpdate() async {
        guard let authority = sponsoringAuthority,
              let endpointString = authority.mcpEndpointURL,
              let endpointURL = URL(string: endpointString) else {
            status = .failed("Authority has no MCP endpoint")
            return
        }

        status = .updating
        let mcpService = MCPService()

        do {
            let result = try await mcpService.callUpdateOperator(
                endpointURL: endpointURL,
                operatorNpub: operatorTarget.npub,
                serviceURL: serviceURL,
                displayName: displayName,
                authorityNpub: authority.npub
            )

            // Update local model
            if let op = operatorTarget as? Operator {
                if !serviceURL.isEmpty { op.mcpEndpointURL = serviceURL }
                if !displayName.isEmpty { op.displayName = displayName }
                try? modelContext.save()
            }

            status = .success(result)
        } catch let MCPError.structuredError(code, message, extras) {
            // Mirror the Adopt remedy flow — branch on the wheel's
            // error_code so the user can resolve the proof gap and retry
            // in-place rather than starting over.
            switch code {
            case "authority_consent_required":
                let npub = extras["authority_npub"] ?? authority.npub
                status = .needsAuthorityProof(npub: npub)
            case "proof_required", "proof_invalid", "proof_refresh_needed":
                status = .needsOperatorProof(npub: operatorTarget.npub)
            default:
                status = .failed(message)
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: - Remedy view sections (mirror of the Adopt-flow pattern)

    @ViewBuilder
    private func proofRemedySection(
        kind: String,
        npub: String,
        explanation: String
    ) -> some View {
        let hasNsec = KeychainService.loadNsec(forNpub: npub) != nil
        Section {
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
                    Task { await acquireProofAndRetryUpdate(for: npub) }
                } label: {
                    Label("Sign with Keychain nsec & retry", systemImage: "signature")
                }
            } else {
                Text("The nsec for this npub is not in this device's Keychain. Use the DM challenge below if you hold the nsec on another Nostr client (e.g. Oxchat).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await acquireProofAndRetryUpdate(for: npub) }
                } label: {
                    Label("Send DM proof challenge", systemImage: "paperplane.fill")
                }
            }
        } header: {
            Text("Proof needed to continue")
        }
    }

    @ViewBuilder
    private func proofAcquisitionInProgressSection(
        npub: String,
        phase: AuthorityCollectionViewModel.ProofPhase
    ) -> some View {
        Section {
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
                    Task { await verifyProofAndRetryUpdate(for: npub) }
                } label: {
                    Label("I've replied — verify now", systemImage: "checkmark.shield")
                }
            case .verifying:
                HStack {
                    ProgressView()
                    Text("Verifying reply…")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Acquiring proof")
        }
    }

    /// Acquire the proof identified by `npub`, then re-run performUpdate.
    /// Auto-sign shortcut when the nsec is in Keychain; otherwise the DM
    /// challenge dance against the sponsoring Authority's MCP.
    private func acquireProofAndRetryUpdate(for npub: String) async {
        guard let authority = sponsoringAuthority,
              let endpointString = authority.mcpEndpointURL,
              let endpointURL = URL(string: endpointString) else {
            status = .failed("Authority has no MCP endpoint")
            return
        }

        if KeychainService.loadNsec(forNpub: npub) != nil {
            // Inline Schnorr — the next callUpdateOperator's
            // argsWithProof will sign from Keychain.
            await performUpdate()
            return
        }

        status = .acquiringProof(npub: npub, phase: .sending)
        let mcpService = MCPService()
        do {
            _ = try await mcpService.callRequestNpubProof(
                endpointURL: endpointURL,
                patronNpub: npub
            )
            status = .acquiringProof(npub: npub, phase: .awaitingReply)
        } catch {
            status = .failed("Failed to send proof challenge: \(error.localizedDescription)")
        }
    }

    /// Drain the relay for the human's reply, then retry the update.
    private func verifyProofAndRetryUpdate(for npub: String) async {
        guard let authority = sponsoringAuthority,
              let endpointString = authority.mcpEndpointURL,
              let endpointURL = URL(string: endpointString) else {
            status = .failed("Authority has no MCP endpoint")
            return
        }
        status = .acquiringProof(npub: npub, phase: .verifying)
        let mcpService = MCPService()
        do {
            // callReceiveNpubProof persists the poison-keyed proof_token
            // to Keychain for (npub, host) — argsWithProof picks it up
            // on the retry's cached-token fallback.
            _ = try await mcpService.callReceiveNpubProof(
                endpointURL: endpointURL,
                patronNpub: npub
            )
            await performUpdate()
        } catch {
            status = .failed("Verification failed: \(error.localizedDescription)")
        }
    }
}
