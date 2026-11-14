import SwiftUI
import SwiftData

/// Operator-initiated **deferred adoption** — "the courtship" (wheel 0.45.0).
///
/// The operator asks a chosen Authority to adopt it by calling
/// `request_adoption` on its OWN MCP endpoint (operator-signed proof). The
/// request is delivered MCP-to-MCP and recorded as *pending* in that
/// Authority's **Pending Requests** queue; the owner approves on their own
/// time. The operator stays orphaned until then.
///
/// Once the ask lands, a device that also holds the chosen Authority's key
/// (one person playing both roles) can approve right here. Otherwise the
/// sheet is done: the request waits in that Authority's Pending Requests.
struct SeekAdoptionSheet: View {
    let operatorTarget: any PricingTarget
    @Bindable var pricingVM: PricingViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Authority.addedAt) private var authorities: [Authority]
    @State private var selectedAuthority: Authority?
    @State private var note: String = ""
    @State private var status: Status = .idle

    enum Status: Equatable {
        case idle
        case asking
        /// The request waits in the Authority's Pending Requests.
        case asked
        /// Approving here, which also sets up the operator's database.
        case approving
        case approved
        /// `asked` says whether the ask landed before the failure.
        case failed(String, asked: Bool)
    }

    /// The ask has landed; nothing more to send.
    private var isSuccess: Bool {
        switch status {
        case .asked, .approving, .approved: return true
        case .failed(_, let asked): return asked
        default: return false
        }
    }

    /// The message of the current failure, or empty.
    private var failureText: String {
        if case .failed(let text, _) = status { return text }
        return ""
    }

    /// This device holds the chosen Authority's key, so its owner is here.
    private var canApproveHere: Bool {
        guard let npub = selectedAuthority?.npub else { return false }
        return KeychainService.loadNsec(forNpub: npub) != nil
    }

    private var steps: (ask: AdoptionStepsView.StepState, approve: AdoptionStepsView.StepState?)? {
        let approveHere: AdoptionStepsView.StepState? = canApproveHere ? .pending : nil
        switch status {
        case .idle: return nil
        case .asking: return (.running, approveHere)
        case .asked: return (.done, approveHere)
        case .approving: return (.done, .running)
        case .approved: return (.done, .done)
        case .failed(_, let asked): return asked ? (.done, .failed) : (.failed, approveHere)
        }
    }

    private var operatorEndpoint: URL? {
        guard let s = operatorTarget.mcpEndpointURL else { return nil }
        return URL(string: s)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(operatorTarget.displayName)
                            .font(.headline)
                        Text(operatorTarget.npub)
                            .font(.caption)
                            .monospaced()
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } header: {
                    Text("Operator seeking adoption")
                } footer: {
                    if operatorEndpoint == nil {
                        Text("This operator has no MCP endpoint URL. Set its public URL in Edit Operator before requesting adoption.")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    if authorities.isEmpty {
                        Text("No Authorities added yet. Add an Authority first.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(authorities) { auth in
                            Button {
                                selectedAuthority = auth
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(auth.displayName)
                                            .font(.subheadline)
                                        Text(String(auth.npub.prefix(20)) + "…")
                                            .font(.caption)
                                            .monospaced()
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selectedAuthority?.npub == auth.npub {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(isSuccess)
                        }
                    }
                } header: {
                    Text("Choose an Authority to request adoption from")
                }

                if !isSuccess {
                    Section {
                        TextField("Note to the Authority owner (optional)", text: $note, axis: .vertical)
                            .lineLimit(1...3)
                    }
                }

                if let steps {
                    Section {
                        AdoptionStepsView(ask: steps.ask, approve: steps.approve)
                        if status == .asked || status == .failed(failureText, asked: true) {
                            if canApproveHere, let auth = selectedAuthority {
                                Button {
                                    Task { await approve(as: auth) }
                                } label: {
                                    Label("Approve now as \(auth.displayName)", systemImage: "checkmark.seal")
                                }
                                .accessibilityIdentifier("approveAdoptionHereButton")
                            } else {
                                Text("It waits in **\(selectedAuthority?.displayName ?? "the Authority")**'s Pending Requests.")
                                    .font(.subheadline)
                            }
                        }
                        if status == .approved {
                            Text("**\(operatorTarget.displayName)** is adopted by **\(selectedAuthority?.displayName ?? "the Authority")**.")
                                .font(.subheadline)
                        }
                    }
                }

                if case .failed(let error, _) = status {
                    Section {
                        Label("Request failed", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Request Adoption")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isSuccess ? "Done" : "Cancel") { dismiss() }
                }
                if !isSuccess {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Request") {
                            guard let auth = selectedAuthority else { return }
                            Task { await sendRequest(to: auth) }
                        }
                        .disabled(selectedAuthority == nil || operatorEndpoint == nil || status == .asking)
                    }
                }
            }
            .onAppear {
                if selectedAuthority == nil { selectedAuthority = authorities.first }
            }
        }
    }

    private func sendRequest(to authority: Authority) async {
        guard let endpoint = operatorEndpoint else {
            status = .failed("Operator has no MCP endpoint URL.", asked: false)
            return
        }
        status = .asking
        do {
            _ = try await MCPService().callRequestAdoption(
                operatorEndpointURL: endpoint,
                operatorNpub: operatorTarget.npub,
                authorityNpub: authority.npub,
                serviceURL: operatorTarget.mcpEndpointURL ?? "",
                note: note
            )
            status = .asked
        } catch {
            status = .failed(error.localizedDescription, asked: false)
        }
    }

    /// The Authority's owner, on this same device, approves the request just sent.
    private func approve(as authority: Authority) async {
        guard let endpointString = authority.mcpEndpointURL,
              let endpointURL = URL(string: endpointString) else {
            status = .failed("Authority has no MCP endpoint.", asked: true)
            return
        }
        status = .approving
        do {
            _ = try await MCPService().callApproveOperatorRequest(
                endpointURL: endpointURL,
                operatorNpub: operatorTarget.npub,
                kind: MCPService.OperatorRequest.adoption,
                authorityNpub: authority.npub
            )
            if let op = operatorTarget as? Operator {
                op.authorityNpub = authority.npub
                try? modelContext.save()
            }
            status = .approved
        } catch {
            status = .failed(error.localizedDescription, asked: true)
        }
    }
}
