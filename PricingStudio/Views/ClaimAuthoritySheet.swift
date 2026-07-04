import DPYCAuthKit
import SwiftUI

struct ClaimAuthoritySheet: View {
    @Environment(\.dismiss) private var dismiss
    let authority: Authority
    var viewModel: AuthorityCollectionViewModel
    @Bindable var chatVM: ChatViewModel

    @State private var nsec = ""
    @State private var derivedNpub: String?
    @State private var keyError: String?
    @State private var keychainError: String?
    @State private var credentialsSent = false
    @State private var isSending = false
    @State private var challengePayload: CourierPayload?
    @State private var challengeSenderHex: String?
    @State private var quickClaimed = false

    private var effectiveNpub: String? { derivedNpub }

    private var isValid: Bool {
        guard let npub = effectiveNpub else { return false }
        return npub.hasPrefix("npub1") && npub.count > 10
    }

    /// Whether the entered nsec derives to this authority's npub — quick claim possible.
    private var npubMatchesAuthority: Bool {
        effectiveNpub == authority.npub
    }

    /// Current phase of the claim flow.
    private enum Phase {
        case form, challenge, verifying, result
    }

    private var phase: Phase {
        if quickClaimed { return .result }
        switch viewModel.claimStatus {
        case .approved, .denied:
            return .result
        case .confirming, .awaitingApproval, .checkingApproval:
            return .verifying
        case .challengeSent:
            return credentialsSent ? .verifying : .challenge
        default:
            return .form
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .form:
                    claimFormContent
                case .challenge:
                    challengeContent
                case .verifying:
                    verifyingContent
                case .result:
                    resultContent
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if phase == .result {
                        EmptyView()
                    } else {
                        Button("Cancel") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if phase == .result {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .onDisappear { nsec = "" }
    }

    // MARK: - Phase 1: Form

    private var claimFormContent: some View {
        Form {
            authoritySection
            nsecSection

            if isValid {
                claimActionsSection
            }

            statusSection
        }
        .navigationTitle("Claim Authority")
    }

    private var claimActionsSection: some View {
        Section {
            if npubMatchesAuthority {
                // Quick claim: nsec maps to this authority's npub
                Button {
                    quickClaimLocally()
                } label: {
                    Label("Claim Authority", systemImage: "checkmark.seal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Button {
                startClaim()
            } label: {
                Label(
                    npubMatchesAuthority ? "Initiate Full Claim Protocol" : "Initiate Claim",
                    systemImage: "envelope.badge.shield.half.filled"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.claimStatus != .idle)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } header: {
            if npubMatchesAuthority {
                Text("This nsec matches the Authority's npub")
            }
        } footer: {
            if npubMatchesAuthority {
                Text("\"Claim Authority\" saves the nsec locally. Use \"Full Claim Protocol\" if the Authority MCP requires DM-based onboarding.")
            }
        }
    }

    // MARK: - Phase 2: Challenge

    private var challengeContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Status banner
                HStack(spacing: 8) {
                    Image(systemName: "envelope.badge")
                        .font(.title3)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Challenge received")
                            .font(.subheadline.bold())
                        Text("Fill in the fields and send your response to complete the claim.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding()
                .background(Color.green.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // Challenge payload (if found)
                if challengePayload != nil {
                    CourierPayloadView(
                        payload: Binding(
                            get: { challengePayload! },
                            set: { challengePayload = $0 }
                        ),
                        onSend: isSending ? nil : { serialized in
                            guard let target = challengeSenderHex else { return }
                            isSending = true
                            Task {
                                await chatVM.sendMessage(to: target, content: serialized)
                                credentialsSent = true
                                await triggerVerification()
                            }
                        }
                    )

                    if isSending {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Sending credentials…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if chatVM.isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading messages from relays…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 40)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text("Waiting for challenge DM…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("The Authority is sending a challenge via Nostr DM. This may take a few seconds.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                        Button("Refresh") {
                            Task { await chatVM.loadConversations() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.top, 20)
                }
            }
            .padding()
        }
        .onChange(of: chatVM.conversations.flatMap(\.messages).count) { _, _ in
            extractChallengePayload()
        }
        .onAppear {
            extractChallengePayload()
        }
        .navigationTitle("Claim Challenge")
    }

    /// Scan conversations for the most recent inbound courier payload and extract it.
    private func extractChallengePayload() {
        var latest: (payload: CourierPayload, senderHex: String, date: Date)?
        for conversation in chatVM.conversations {
            for dm in conversation.messages where !dm.isFromMe {
                if let payload = CourierPayload.parse(dm.content) {
                    let dmDate = dm.createdAt
                    if latest == nil || dmDate > latest!.date {
                        let hex: String
                        if let opNpub = payload.provenance.operatorNpub,
                           opNpub.hasPrefix("npub1"),
                           let h = try? NostrKeyService.publicKeyHexFromNpub(opNpub) {
                            hex = h
                        } else {
                            hex = dm.senderPubkeyHex
                        }
                        latest = (payload, hex, dmDate)
                    }
                }
            }
        }
        if let latest {
            challengePayload = latest.payload
            challengeSenderHex = latest.senderHex
        }
    }

    // MARK: - Phase 3: Verifying

    private var verifyingContent: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView()
                .scaleEffect(1.5)

            Text(verifyingStatusText)
                .font(.title3.bold())

            Text(verifyingDetailText)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 8) {
                claimStepRow("Credentials sent", done: true)
                claimStepRow("Authority verifying reply", done: viewModel.claimStatus != .confirming)
                claimStepRow("Prime Authority approval", done: false)
            }
            .padding(.horizontal, 40)

            Spacer()
        }
        .navigationTitle("Verifying Claim")
    }

    private var verifyingStatusText: String {
        switch viewModel.claimStatus {
        case .confirming: return "Verifying your reply…"
        case .awaitingApproval: return "Escalating to Prime…"
        case .checkingApproval: return "Checking approval…"
        default: return "Processing…"
        }
    }

    private var verifyingDetailText: String {
        switch viewModel.claimStatus {
        case .confirming:
            return "The Authority is reading the Nostr stream to verify your challenge response."
        case .awaitingApproval:
            return "Your response was verified. Requesting approval from the Prime Authority."
        case .checkingApproval:
            return "Waiting for the Prime Authority to approve your claim."
        default:
            return "This may take a few moments."
        }
    }

    @ViewBuilder
    private func claimStepRow(_ label: String, done: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
                .font(.caption)
            Text(label)
                .font(.caption)
                .foregroundStyle(done ? .primary : .secondary)
        }
    }

    // MARK: - Phase 4: Result

    private var resultContent: some View {
        VStack(spacing: 24) {
            Spacer()

            if quickClaimed {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)

                Text("Authority Claimed")
                    .font(.title2.bold())

                Text("The nsec has been saved. You can now manage \(authority.displayName) from this device.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)
            } else if case .approved(let message) = viewModel.claimStatus {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)

                Text("Authority Claimed")
                    .font(.title2.bold())

                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)
            } else if case .denied(let message) = viewModel.claimStatus {
                Image(systemName: "xmark.seal.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.red)

                Text("Claim Denied")
                    .font(.title2.bold())

                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)
            }

            Spacer()
        }
        .navigationTitle({
            if quickClaimed { return "Claimed" }
            if case .approved = viewModel.claimStatus { return "Claimed" }
            return "Claim Result"
        }())
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
                    Label(
                        npubMatchesAuthority ? "npub matches this Authority" : "npub derived",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(npubMatchesAuthority ? .green : .orange)
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
        case .challengeSent, .confirming, .awaitingApproval, .checkingApproval, .approved, .denied:
            EmptyView()
        case .failed(let message):
            Section {
                Label {
                    Text(message)
                        .font(.caption)
                } icon: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
                Button("Try Again") {
                    viewModel.claimStatus = .idle
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

    /// Quick claim: nsec matches authority npub, just save it locally.
    private func quickClaimLocally() {
        guard let candidateNpub = effectiveNpub else { return }

        let trimmedNsec = nsec.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try KeychainService.saveNsec(trimmedNsec, forNpub: candidateNpub)
        } catch {
            keychainError = "Failed to save nsec: \(error.localizedDescription)"
            return
        }

        quickClaimed = true
    }

    /// After credentials are sent via DM, call confirm + check_approval on the MCP.
    private func triggerVerification() async {
        guard let candidateNpub = effectiveNpub,
              let endpointStr = authority.mcpEndpointURL,
              let endpointURL = URL(string: endpointStr) else { return }

        await viewModel.confirmAndCheckApproval(
            authorityEndpoint: endpointURL,
            candidateNpub: candidateNpub
        )
    }

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
              let endpointURL = URL(string: endpointStr) else {
            viewModel.claimStatus = .failed("Authority has no MCP endpoint URL. Edit the authority to set one, or wait for auto-discovery.")
            return
        }

        let trimmedNsec = nsec.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNsec.isEmpty {
            do {
                try KeychainService.saveNsec(trimmedNsec, forNpub: candidateNpub)
            } catch {
                keychainError = "Failed to save nsec: \(error.localizedDescription)"
                return
            }
        }

        Task {
            do {
                // Establish DPYC session before claim — server requires npub in _dpyc_sessions.
                // The candidate is registering its own npub against itself, so the candidate's
                // nsec serves as both operator-side and Authority-side consent witness.
                let mcpService = MCPService()
                _ = try await mcpService.callRegisterOperator(
                    endpointURL: endpointURL,
                    operatorNpub: candidateNpub,
                    authorityNpub: candidateNpub
                )
                await viewModel.initiateAuthorityClaim(
                    authorityEndpoint: endpointURL,
                    candidateNpub: candidateNpub
                )

                if viewModel.claimStatus == .challengeSent {
                    let identity = ChatIdentity(
                        npub: candidateNpub,
                        displayName: "Claim Candidate",
                        entityType: .operator
                    )
                    chatVM.switchIdentity(to: identity)
                }
            } catch {
                viewModel.claimStatus = .failed("Session registration failed: \(error.localizedDescription)")
            }
        }
    }

}
