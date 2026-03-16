import SwiftUI

struct ClaimAuthoritySheet: View {
    @Environment(\.dismiss) private var dismiss
    let authority: Authority
    var viewModel: AuthorityCollectionViewModel

    @State private var nsec = ""
    @State private var derivedNpub: String?
    @State private var keyError: String?
    @State private var keychainError: String?

    private var effectiveNpub: String? { derivedNpub }

    private var isValid: Bool {
        guard let npub = effectiveNpub else { return false }
        return npub.hasPrefix("npub1") && npub.count > 10
    }

    var body: some View {
        NavigationStack {
            Form {
                authoritySection
                nsecSection
                statusSection
            }
            .navigationTitle("Claim Authority")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Initiate Claim") {
                        startClaim()
                    }
                    .disabled(!isValid || viewModel.claimStatus != .idle)
                }
            }
            .onDisappear { nsec = "" }
        }
    }

    // MARK: - Sections

    private var authoritySection: some View {
        Section {
            HStack {
                Image(systemName: "building.columns.fill")
                    .foregroundStyle(.blue)
                Text(authority.displayName)
                    .fontWeight(.medium)
            }
            if let endpoint = authority.mcpEndpointURL {
                Text(endpoint)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Authority")
        }
    }

    private var nsecSection: some View {
        Section {
            SecureField("nsec1... (unclaimed operator)", text: $nsec)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .monospaced()
                .font(.callout)
                .onChange(of: nsec) { _, newValue in
                    deriveNpub(newValue)
                }
        } header: {
            Text("Operator nsec")
        } footer: {
            if let error = keychainError {
                Text(error).foregroundStyle(.red)
            } else if let error = keyError {
                Text(error).foregroundStyle(.red)
            } else if let npub = derivedNpub {
                VStack(alignment: .leading, spacing: 4) {
                    Label("npub derived", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(npub)
                        .font(.caption2)
                        .monospaced()
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Enter the nsec for the deployed-but-unclaimed Operator. The npub will be derived and registered with the Authority.")
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch viewModel.claimStatus {
        case .idle:
            EmptyView()
        case .connecting:
            statusRow("Connecting to Authority...", icon: "network", color: .blue)
        case .registering:
            statusRow("Registering candidate npub...", icon: "arrow.triangle.2.circlepath", color: .orange)
        case .challengeSent:
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Challenge sent")
                            .fontWeight(.medium)
                        Text("Check your DMs for the credential payload from the Authority. Fill in the fields and send your reply.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } header: {
                Text("Status")
            }
        case .failed(let message):
            Section {
                Label {
                    Text(message)
                        .font(.caption)
                } icon: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Error")
            }
        }
    }

    @ViewBuilder
    private func statusRow(_ text: String, icon: String, color: Color) -> some View {
        Section {
            Label(text, systemImage: icon)
                .foregroundStyle(color)
        } header: {
            Text("Status")
        }
    }

    // MARK: - Actions

    private func deriveNpub(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            derivedNpub = nil
            keyError = nil
            return
        }
        guard trimmed.hasPrefix("nsec1") else {
            derivedNpub = nil
            keyError = "Must start with nsec1"
            return
        }
        do {
            derivedNpub = try NostrKeyService.npubFromNsec(trimmed)
            keyError = nil
        } catch {
            derivedNpub = nil
            keyError = error.localizedDescription
        }
    }

    private func startClaim() {
        guard let candidateNpub = effectiveNpub,
              let endpointStr = authority.mcpEndpointURL,
              let endpointURL = URL(string: endpointStr) else { return }

        // Save nsec to keychain for the candidate operator
        let trimmedNsec = nsec.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNsec.isEmpty {
            do {
                try KeychainService.saveNsec(trimmedNsec, forNpub: candidateNpub)
            } catch {
                keychainError = "Failed to save nsec: \(error.localizedDescription)"
                return
            }
        }

        guard let token = KeychainService.loadToken(forOperator: authority.npub), !token.isEmpty else {
            viewModel.claimStatus = .failed("No bearer token found for this Authority. Add one in the Authority edit sheet first.")
            return
        }

        Task {
            await viewModel.initiateAuthorityClaim(
                authorityEndpoint: endpointURL,
                candidateNpub: candidateNpub,
                bearerToken: token
            )
        }
    }
}
