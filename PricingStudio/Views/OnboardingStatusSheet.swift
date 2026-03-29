import SwiftUI

/// Standalone sheet showing an operator's configuration readiness.
/// Calls get_onboarding_status on the operator's MCP and displays
/// configured/missing fields with actionable remediation.
struct OnboardingStatusSheet: View {
    let operator_: Operator
    @Environment(\.dismiss) private var dismiss

    @State private var status: MCPService.OnboardingStatus?
    @State private var loading = true
    @State private var error: String?
    @State private var showingCourierCard = false

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Checking configuration...")
                } else if let status {
                    statusContent(status)
                } else if let error {
                    ContentUnavailableView {
                        Label("Check Failed", systemImage: "xmark.circle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") {
                            Task { await loadStatus() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadStatus() }
            .overlay(alignment: .bottomTrailing) {
                if showingCourierCard,
                   let endpoint = operator_.mcpEndpointURL,
                   let url = URL(string: endpoint),
                   let status {
                    SecureCourierCard(
                        operatorName: operator_.displayName,
                        operatorNpub: operator_.npub,
                        endpointURL: url,
                        credentialService: status.credentialService ?? "",
                        missingSecrets: status.missing
                            .filter { $0.category == "secret" }
                            .map { fieldLabel($0.field) },
                        onDismiss: { showingCourierCard = false }
                    )
                    .frame(width: 340)
                    .padding()
                }
            }
        }
    }

    @ViewBuilder
    private func statusContent(_ status: MCPService.OnboardingStatus) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(operator_.displayName)
                        .font(.headline)
                    if let url = operator_.mcpEndpointURL {
                        Text(url)
                            .font(.caption)
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Configured") {
                if status.configured.isEmpty {
                    Text("No fields configured yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(status.configured, id: \.field) { field in
                        Label(fieldLabel(field.field), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }

            if !status.missing.isEmpty {
                Section("Missing") {
                    ForEach(status.missing, id: \.field) { field in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(fieldLabel(field.field), systemImage: categoryIcon(field.category))
                                .foregroundStyle(categoryColor(field.category))
                            if let how = field.how {
                                Text(how)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Actions") {
                    let hasAuthority = status.missing.contains { $0.category == "authority" }
                    let hasSecrets = status.missing.contains { $0.category == "secret" }

                    if hasAuthority {
                        Button {
                            Task { await loadStatus() }
                        } label: {
                            Label("Refresh Config from Authority", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .tint(.blue)
                    }

                    if hasSecrets {
                        Button {
                            showingCourierCard = true
                        } label: {
                            Label("Deliver Secrets via Secure Courier", systemImage: "lock.shield")
                        }
                        .tint(.orange)
                    }
                }
            }

            if status.ready {
                Section {
                    Label("Operator is fully configured", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .fontWeight(.medium)
                }
            }

            Section {
                Text(status.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadStatus() async {
        guard let endpoint = operator_.mcpEndpointURL,
              let endpointURL = URL(string: endpoint) else {
            error = "No MCP endpoint URL configured"
            loading = false
            return
        }

        loading = true
        error = nil

        do {
            let oauthService = OAuthService()
            let host = endpointURL.host ?? operator_.npub
            let token: String
            if let bundle = KeychainService.loadTokenBundle(forPatron: operator_.npub, operator: host),
               !bundle.isExpired {
                token = bundle.accessToken
            } else {
                let bundle = try await oauthService.authenticate(mcpEndpoint: endpointURL)
                try? KeychainService.saveTokenBundle(bundle, forPatron: operator_.npub, operator: host)
                token = bundle.accessToken
            }

            status = try await MCPService().callGetOnboardingStatus(
                endpointURL: endpointURL,
                bearerToken: token
            )
        } catch {
            self.error = error.localizedDescription
        }

        loading = false
    }


    private func fieldLabel(_ field: String) -> String {
        field.replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private func categoryIcon(_ category: String) -> String {
        switch category {
        case "authority": return "building.columns"
        case "secret": return "lock.shield"
        case "identity": return "key"
        default: return "circle"
        }
    }

    private func categoryColor(_ category: String) -> Color {
        switch category {
        case "authority": return .blue
        case "secret": return .orange
        case "identity": return .purple
        default: return .secondary
        }
    }
}
