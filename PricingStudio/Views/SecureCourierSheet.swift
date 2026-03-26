import SwiftUI

/// Guided Secure Courier flow:
/// explain → call MCP → show poison → wait for user reply → collect credentials → done.
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
        case collecting
        case received(String)
        case collectFailed(poison: String, error: String)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    switch phase {
                    case .explain:
                        explainView
                    case .calling:
                        callingView
                    case .ready(let poison):
                        readyView(poison: poison)
                    case .collecting:
                        collectingView
                    case .received(let message):
                        receivedView(message: message)
                    case .collectFailed(let poison, let error):
                        collectFailedView(poison: poison, error: error)
                    case .failed(let error):
                        failedView(error: error)
                    }
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Secure Courier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .calling = phase {
                        // No cancel during the call
                    } else if case .collecting = phase {
                        // No cancel during collect
                    } else {
                        Button("Close") { dismiss() }
                    }
                }
            }
        }
    }

    // MARK: - 1. Explain

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

            VStack(alignment: .leading, spacing: 8) {
                Label("The operator sends you a secure form via Nostr DM", systemImage: "1.circle.fill")
                Label("You fill in the secrets and reply", systemImage: "2.circle.fill")
                Label("Come back here and tap Collect to deliver them", systemImage: "3.circle.fill")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

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

    // MARK: - 2. Calling

    private var callingView: some View {
        VStack(spacing: 24) {
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(.orange.opacity(0.3), lineWidth: 2)
                        .frame(width: CGFloat(80 + i * 30), height: CGFloat(80 + i * 30))
                        .scaleEffect(pulseScale)
                        .opacity(pulseOpacity)
                        .animation(
                            .easeInOut(duration: 1.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.3),
                            value: phase.isAnimating
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

    // MARK: - 3. Ready (waiting for user to reply)

    private func readyView(poison: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Channel Open")
                .font(.title3.bold())

            Text("A credential form has been sent to your Nostr DMs.")
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

                Text("This confirms the message is authentic.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            VStack(spacing: 8) {
                Text("After you've replied with your secrets:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    phase = .collecting
                    Task { await collectCredentials() }
                } label: {
                    Label("Collect Reply", systemImage: "envelope.open.fill")
                        .frame(maxWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Text("This tells the operator to check for your encrypted reply.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - 4. Collecting

    private var collectingView: some View {
        VStack(spacing: 24) {
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(.green.opacity(0.3), lineWidth: 2)
                        .frame(width: CGFloat(80 + i * 30), height: CGFloat(80 + i * 30))
                        .scaleEffect(pulseScale)
                        .opacity(pulseOpacity)
                        .animation(
                            .easeInOut(duration: 1.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.3),
                            value: phase.isAnimating
                        )
                }

                Image(systemName: "envelope.open.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.green)
            }
            .frame(height: 160)

            Text("Collecting credentials...")
                .font(.headline)

            HStack(spacing: 8) {
                ProgressView()
                Text("Scanning Nostr relays for your encrypted reply")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 5. Received

    private func receivedView(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)

            Text("Credentials Received")
                .font(.title3.bold())

            Text("The operator has securely received and stored your credentials.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(10)
                    .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Collect Failed (can retry)

    private func collectFailedView(poison: String, error: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "envelope.badge.shield.half.filled.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("Reply Not Found Yet")
                .font(.title3.bold())

            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Text("Make sure you've replied to the DM with the poison phrase \"\(poison)\" and all requested fields filled in.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            HStack(spacing: 16) {
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)

                Button {
                    phase = .collecting
                    Task { await collectCredentials() }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
    }

    // MARK: - Failed (channel open failed)

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

    // MARK: - Network Flows

    @State private var currentPoison: String = ""

    private func resolveToken() async throws -> String {
        let host = endpointURL.host ?? operatorNpub
        if let bundle = KeychainService.loadTokenBundle(forPatron: operatorNpub, operator: host),
           !bundle.isExpired {
            return bundle.accessToken
        }
        let bundle = try await OAuthService().authenticate(mcpEndpoint: endpointURL)
        try? KeychainService.saveTokenBundle(bundle, forPatron: operatorNpub, operator: host)
        return bundle.accessToken
    }

    private func beginCourierFlow() async {
        do {
            let token = try await resolveToken()
            let result = try await MCPService().callRequestCredentialChannel(
                endpointURL: endpointURL,
                bearerToken: token,
                senderNpub: operatorNpub
            )

            if let data = result.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let poison = json["poison"] as? String {
                currentPoison = poison
                phase = .ready(poison: poison)
            } else {
                currentPoison = ""
                phase = .ready(poison: "check your DMs")
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func collectCredentials() async {
        do {
            let token = try await resolveToken()
            let result = try await MCPService().callReceiveCredentials(
                endpointURL: endpointURL,
                bearerToken: token,
                senderNpub: operatorNpub
            )

            // Parse result for success
            if let data = result.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if json["success"] as? Bool == true {
                    let msg = json["message"] as? String ?? "Credentials stored successfully."
                    phase = .received(msg)
                } else {
                    let err = json["error"] as? String ?? "No reply found on relays."
                    phase = .collectFailed(poison: currentPoison, error: err)
                }
            } else {
                // Non-JSON response — treat as success message
                phase = .received(result)
            }
        } catch {
            phase = .collectFailed(poison: currentPoison, error: error.localizedDescription)
        }
    }

    // MARK: - Animation Helpers

    private var pulseScale: CGFloat { phase.isAnimating ? 1.1 : 1.0 }
    private var pulseOpacity: Double { phase.isAnimating ? 0.6 : 0.3 }
}

extension SecureCourierSheet.Phase {
    var isAnimating: Bool {
        switch self {
        case .calling, .collecting: return true
        default: return false
        }
    }

    var isCalling: Bool {
        if case .calling = self { return true }
        return false
    }
}
