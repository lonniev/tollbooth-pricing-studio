import SwiftUI
import SwiftData

/// Operator-initiated **deferred adoption** — "the courtship" (wheel 0.45.0).
///
/// The operator asks a chosen Authority to adopt it by calling
/// `request_adoption` on its OWN MCP endpoint (operator-signed proof). The
/// request is delivered MCP-to-MCP and recorded as *pending* in that
/// Authority's **Pending Adoptions** queue; the owner approves on their own
/// time. The operator stays orphaned until then.
///
/// This is distinct from `RequestAdoptionSheet`, which performs the inline
/// `register_operator` (Authority-side, immediate-consent) flow used when the
/// Authority owner adopts/moves an operator directly.
struct SeekAdoptionSheet: View {
    let operatorTarget: any PricingTarget
    @Bindable var pricingVM: PricingViewModel
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Authority.addedAt) private var authorities: [Authority]
    @State private var selectedAuthority: Authority?
    @State private var note: String = ""
    @State private var status: Status = .idle

    enum Status: Equatable {
        case idle
        case requesting
        case success(String)
        case failed(String)
    }

    private var isSuccess: Bool {
        if case .success = status { return true }
        return false
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

                if case .requesting = status {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Sending adoption request…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if case .success = status {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Adoption requested", systemImage: "paperplane.fill")
                                .font(.headline)
                                .foregroundStyle(.green)
                            Text("**\(selectedAuthority?.displayName ?? "The Authority")**'s owner will review this in their **Pending Adoptions** queue. **\(operatorTarget.displayName)** stays orphaned until they approve — then it's provisioned automatically.")
                                .font(.subheadline)
                        }
                    }
                }

                if case .failed(let error) = status {
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
                        .disabled(selectedAuthority == nil || operatorEndpoint == nil || status == .requesting)
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
            status = .failed("Operator has no MCP endpoint URL.")
            return
        }
        status = .requesting
        do {
            _ = try await MCPService().callRequestAdoption(
                operatorEndpointURL: endpoint,
                operatorNpub: operatorTarget.npub,
                authorityNpub: authority.npub,
                serviceURL: operatorTarget.mcpEndpointURL ?? "",
                note: note
            )
            status = .success(authority.displayName)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
