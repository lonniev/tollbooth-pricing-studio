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

        static func == (lhs: UpdateStatus, rhs: UpdateStatus) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.updating, .updating): return true
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
                            status == .updating
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
        let oauthService = OAuthService()

        do {
            let host = endpointURL.host ?? authority.npub
            let token: String
            if let bundle = KeychainService.loadTokenBundle(forPatron: operatorTarget.npub, operator: host),
               !bundle.isExpired {
                token = bundle.accessToken
            } else {
                let bundle = try await oauthService.authenticate(mcpEndpoint: endpointURL)
                try? KeychainService.saveTokenBundle(bundle, forPatron: operatorTarget.npub, operator: host)
                token = bundle.accessToken
            }

            let result = try await mcpService.callUpdateOperator(
                endpointURL: endpointURL,
                operatorNpub: operatorTarget.npub,
                serviceURL: serviceURL,
                displayName: displayName
            )

            // Update local model
            if let op = operatorTarget as? Operator {
                if !serviceURL.isEmpty { op.mcpEndpointURL = serviceURL }
                if !displayName.isEmpty { op.displayName = displayName }
                try? modelContext.save()
            }

            status = .success(result)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
