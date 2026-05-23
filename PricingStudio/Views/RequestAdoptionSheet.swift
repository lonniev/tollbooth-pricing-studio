import SwiftUI
import SwiftData

/// Operator-initiated adoption request — the Operator picks an Authority and asks to be adopted.
/// Mirrors the Authority-side AdoptOperatorSheet but starts from the Operator's "Not Registered" view.
struct RequestAdoptionSheet: View {
    let operatorTarget: any PricingTarget
    @Bindable var pricingVM: PricingViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Authority.addedAt) private var authorities: [Authority]
    @State private var selectedAuthority: Authority?
    @State private var status: AdoptionStatus = .idle

    enum AdoptionStatus: Equatable {
        case idle
        case registering
        case success(String)
        case failed(String)

        static func == (lhs: AdoptionStatus, rhs: AdoptionStatus) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.registering, .registering): return true
            case (.success(let a), .success(let b)): return a == b
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    private var isSuccess: Bool {
        if case .success = status { return true }
        return false
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
                    }
                } header: {
                    Text("Operator")
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
                        }
                    }
                } header: {
                    Text("Choose an Authority to adopt this Operator")
                }

                if case .registering = status {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Requesting adoption…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if case .success = status {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Registered", systemImage: "checkmark.circle.fill")
                                .font(.headline)
                                .foregroundStyle(.green)
                            Text("**\(operatorTarget.displayName)** is now registered with **\(selectedAuthority?.displayName ?? "Authority")**.")
                                .font(.subheadline)
                            Text("The operator can now purchase credits and serve toll calls.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
            .navigationTitle(isSuccess ? "Registered" : "Register Operator")
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
                        Button("Request") {
                            guard let auth = selectedAuthority else { return }
                            Task { await requestAdoption(authority: auth) }
                        }
                        .disabled(selectedAuthority == nil || status == .registering)
                    }
                }
            }
        }
    }

    private func requestAdoption(authority: Authority) async {
        guard let endpointString = authority.mcpEndpointURL,
              let endpointURL = URL(string: endpointString) else {
            status = .failed("Authority has no MCP endpoint")
            return
        }

        status = .registering
        let mcpService = MCPService()

        do {
            let result = try await mcpService.callRegisterOperator(
                endpointURL: endpointURL,
                operatorNpub: operatorTarget.npub,
                operatorServiceURL: (operatorTarget as? Operator)?.mcpEndpointURL ?? "",
                authorityNpub: authority.npub
            )

            // Update the operator's authority link locally
            if let op = operatorTarget as? Operator {
                op.authorityNpub = authority.npub
                try? modelContext.save()
            }

            status = .success(result)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
