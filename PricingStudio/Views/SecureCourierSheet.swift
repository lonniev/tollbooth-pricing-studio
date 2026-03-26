import SwiftUI

/// Guided Secure Courier flow: explain → call MCP → show poison phrase → go to messages.
struct SecureCourierSheet: View {
    let operatorName: String
    let operatorNpub: String
    let endpointURL: URL
    let missingSecrets: [String]
    var onGoToMessages: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .explain

    enum Phase {
        case explain
        case calling
        case ready(poison: String)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch phase {
                case .explain:
                    explainView
                case .calling:
                    callingView
                case .ready(let poison):
                    readyView(poison: poison)
                case .failed(let error):
                    failedView(error: error)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Secure Courier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .calling = phase {
                        // No cancel during the call
                    } else {
                        Button("Close") { dismiss() }
                    }
                }
            }
        }
    }

    // MARK: - Explain

    private var explainView: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)

            Text("Deliver Secrets to \(operatorName)")
                .font(.title3.bold())
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 12) {
                Label("The operator needs these credentials:", systemImage: "list.bullet")
                    .font(.subheadline.bold())

                ForEach(missingSecrets, id: \.self) { secret in
                    HStack(spacing: 6) {
                        Image(systemName: "key.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text(secret)
                            .font(.subheadline.monospaced())
                    }
                }
            }
            .padding()
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))

            Text("When you tap Begin, the operator will send you a secure credential form via encrypted Nostr DM. You'll fill in the values and reply.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            HStack(spacing: 16) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)

                Button {
                    phase = .calling
                    Task { await beginCourierFlow() }
                } label: {
                    Label("Begin", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
    }

    // MARK: - Calling

    private var callingView: some View {
        VStack(spacing: 24) {
            ZStack {
                // Pulsing rings
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(.orange.opacity(0.3), lineWidth: 2)
                        .frame(width: CGFloat(80 + i * 30), height: CGFloat(80 + i * 30))
                        .scaleEffect(pulseScale(for: i))
                        .opacity(pulseOpacity(for: i))
                        .animation(
                            .easeInOut(duration: 1.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.3),
                            value: phase.isCalling
                        )
                }

                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
            }
            .frame(height: 160)

            Text("Contacting \(operatorName)...")
                .font(.headline)

            HStack(spacing: 8) {
                ProgressView()
                Text("Opening Secure Courier channel")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Ready

    private func readyView(poison: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)

            Text("Channel Open")
                .font(.title3.bold())

            Text("A secure credential form is on its way to your Nostr DMs.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            VStack(spacing: 8) {
                Text("Look for the poison phrase:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("\"\(poison)\"")
                    .font(.title2.bold())
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

                Text("This phrase confirms the message is authentic.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text("Fill in the requested secrets and reply via encrypted DM.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 10) {
                if let onGoToMessages {
                    Button {
                        onGoToMessages()
                        dismiss()
                    } label: {
                        Label("Go to Messages", systemImage: "envelope.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Failed

    private func failedView(error: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "xmark.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(.red)

            Text("Channel Failed")
                .font(.title3.bold())

            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            HStack(spacing: 16) {
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)

                Button("Retry") {
                    phase = .calling
                    Task { await beginCourierFlow() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Flow

    private func beginCourierFlow() async {
        do {
            let oauthService = OAuthService()
            let host = endpointURL.host ?? operatorNpub
            let token: String
            if let bundle = KeychainService.loadTokenBundle(forPatron: operatorNpub, operator: host),
               !bundle.isExpired {
                token = bundle.accessToken
            } else {
                let bundle = try await oauthService.authenticate(mcpEndpoint: endpointURL)
                try? KeychainService.saveTokenBundle(bundle, forPatron: operatorNpub, operator: host)
                token = bundle.accessToken
            }

            let result = try await MCPService().callRequestCredentialChannel(
                endpointURL: endpointURL,
                bearerToken: token,
                senderNpub: operatorNpub
            )

            // Extract poison phrase
            if let data = result.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let poison = json["poison"] as? String {
                phase = .ready(poison: poison)
            } else {
                phase = .ready(poison: "check your DMs")
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func pulseScale(for index: Int) -> CGFloat {
        if case .calling = phase { return 1.1 }
        return 1.0
    }

    private func pulseOpacity(for index: Int) -> Double {
        if case .calling = phase { return 0.6 }
        return 0.3
    }
}

extension SecureCourierSheet.Phase {
    var isCalling: Bool {
        if case .calling = self { return true }
        return false
    }
}
