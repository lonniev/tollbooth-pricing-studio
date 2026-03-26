import SwiftUI

/// Floating card for the Secure Courier flow — stays on screen while
/// the user navigates to Messages and back.
struct SecureCourierCard: View {
    let operatorName: String
    let operatorNpub: String
    let endpointURL: URL
    let missingSecrets: [String]
    var onDismiss: () -> Void

    @State private var phase: Phase = .explain
    @State private var currentPoison: String = ""
    @State private var expanded = true

    enum Phase: Equatable {
        case explain
        case calling
        case ready(poison: String)
        case collecting
        case received(String)
        case collectFailed(poison: String, error: String)
        case failed(String)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.explain, .explain), (.calling, .calling), (.collecting, .collecting): return true
            case (.ready(let a), .ready(let b)): return a == b
            case (.received(let a), .received(let b)): return a == b
            case (.failed(let a), .failed(let b)): return a == b
            case (.collectFailed(let ap, let ae), .collectFailed(let bp, let be)): return ap == bp && ae == be
            default: return false
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header — always visible, tap to expand/collapse
            headerBar

            if expanded {
                Divider()
                ScrollView {
                    phaseContent
                        .padding(16)
                }
                .frame(maxHeight: 360)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: phaseIcon)
                .foregroundStyle(phaseColor)
                .font(.subheadline)

            Text(phaseTitle)
                .font(.subheadline.bold())
                .lineLimit(1)

            Spacer()

            Button {
                withAnimation { expanded.toggle() }
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { expanded.toggle() } }
    }

    private var phaseIcon: String {
        switch phase {
        case .explain: return "lock.shield.fill"
        case .calling: return "antenna.radiowaves.left.and.right"
        case .ready: return "checkmark.shield.fill"
        case .collecting: return "envelope.open.fill"
        case .received: return "checkmark.seal.fill"
        case .collectFailed: return "envelope.badge.shield.half.filled.fill"
        case .failed: return "xmark.shield.fill"
        }
    }

    private var phaseColor: Color {
        switch phase {
        case .explain, .calling: return .orange
        case .ready: return .green
        case .collecting: return .green
        case .received: return .green
        case .collectFailed: return .orange
        case .failed: return .red
        }
    }

    private var phaseTitle: String {
        switch phase {
        case .explain: return "Secure Courier — \(operatorName)"
        case .calling: return "Contacting \(operatorName)..."
        case .ready: return "Channel Open — Reply via DM"
        case .collecting: return "Collecting Credentials..."
        case .received: return "Credentials Received"
        case .collectFailed: return "Reply Not Found"
        case .failed: return "Channel Failed"
        }
    }

    // MARK: - Phase Content

    @ViewBuilder
    private var phaseContent: some View {
        switch phase {
        case .explain:
            explainContent
        case .calling:
            callingContent
        case .ready(let poison):
            readyContent(poison: poison)
        case .collecting:
            collectingContent
        case .received(let message):
            receivedContent(message: message)
        case .collectFailed(let poison, let error):
            collectFailedContent(poison: poison, error: error)
        case .failed(let error):
            failedContent(error: error)
        }
    }

    private var explainContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(missingSecrets, id: \.self) { secret in
                HStack(spacing: 6) {
                    Image(systemName: "key.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text(secret)
                        .font(.caption.monospaced())
                }
            }

            Text("Tap Begin to open a Secure Courier channel. The operator sends a credential form via Nostr DM. You fill in the values and reply, then come back here to collect.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button {
                    phase = .calling
                    Task { await beginCourierFlow() }
                } label: {
                    Label("Begin", systemImage: "paperplane.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.orange)
            }
        }
    }

    private var callingContent: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Opening Secure Courier channel...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func readyContent(poison: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Check your Nostr DMs for the credential form.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text("Poison phrase:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\"\(poison)\"")
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)
            }
            .padding(8)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            Text("Fill in the secrets and reply via encrypted DM, then:")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button {
                    phase = .collecting
                    Task { await collectCredentials() }
                } label: {
                    Label("Collect Reply", systemImage: "envelope.open.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.green)
            }
        }
    }

    private var collectingContent: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Scanning relays for your encrypted reply...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func receivedContent(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Credentials securely stored.", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)

            if !message.isEmpty {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Done") { onDismiss() }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }

    private func collectFailedContent(poison: String, error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(error)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text("Make sure you replied with poison phrase \"\(poison)\" and all fields filled in.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button {
                    phase = .collecting
                    Task { await collectCredentials() }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.green)
            }
        }
    }

    private func failedContent(error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(error)
                .font(.caption2)
                .foregroundStyle(.red)

            HStack {
                Spacer()
                Button("Retry") {
                    phase = .calling
                    Task { await beginCourierFlow() }
                }
                .font(.caption)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Network

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
                phase = .received(result)
            }
        } catch {
            phase = .collectFailed(poison: currentPoison, error: error.localizedDescription)
        }
    }
}
