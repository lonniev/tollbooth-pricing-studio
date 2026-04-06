import SwiftUI

/// Parameters for initiating a Secure Courier flow.
struct CourierParams {
    let operatorName: String
    let operatorNpub: String
    let endpointURL: URL
    let credentialService: String
    let missingSecrets: [String]
    var greeting: String = ""
    var senderNpub: String = ""  // non-empty for patron context
}

/// Floating card for the Secure Courier flow — stays on screen while
/// the user navigates to Messages and back.
///
/// When used from the patron context, set `senderNpub` to the patron's npub.
/// Auth and DM sender will use that identity instead of `operatorNpub`.
struct SecureCourierCard: View {
    let operatorName: String
    let operatorNpub: String
    let endpointURL: URL
    let credentialService: String
    let missingSecrets: [String]
    var greeting: String = ""
    var senderNpub: String = ""  // defaults to operatorNpub when empty
    var onOpenMessages: (() -> Void)?  // optional: switch to Messages tab
    var onDismiss: () -> Void

    /// The npub to use for auth and as the DM sender identity.
    private var effectiveSender: String { senderNpub.isEmpty ? operatorNpub : senderNpub }

    @State private var phase: Phase = .explain
    @State private var currentPoison: String = ""
    @State private var credentialCard: String = ""
    @State private var ncredInput: String = ""
    @State private var showNcredField = false
    @State private var expanded = true
    @State private var dragOffset: CGSize = .zero
    @State private var savedOffset: CGSize = .zero
    @State private var showDismissConfirm = false
    @State private var ncredSaved = false

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
            headerBar

            if expanded {
                Divider()
                ScrollView {
                    phaseContent
                        .padding(12)
                }
                .frame(maxHeight: 300)
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willEnterForegroundNotification
        )) { _ in
            // Auto-collect when returning from Messages (user likely sent their DM)
            if case .ready = phase {
                phase = .collecting
                Task { await collectCredentials() }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .offset(x: savedOffset.width + dragOffset.width,
                y: savedOffset.height + dragOffset.height)
        .gesture(
            DragGesture()
                .onChanged { value in
                    dragOffset = value.translation
                }
                .onEnded { value in
                    let newY = savedOffset.height + value.translation.height
                    savedOffset = CGSize(
                        width: savedOffset.width + value.translation.width,
                        // Clamp: don't let the card go above its origin
                        height: max(0, newY)
                    )
                    dragOffset = .zero
                }
        )
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
                if isActivePhase {
                    showDismissConfirm = true
                } else {
                    onDismiss()
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(isActivePhase ? .tertiary : .secondary)
            }
            .buttonStyle(.plain)
            .confirmationDialog(
                "Secure Courier is in progress",
                isPresented: $showDismissConfirm,
                titleVisibility: .visible
            ) {
                Button("Abandon Courier Flow", role: .destructive) {
                    onDismiss()
                }
                Button("Continue", role: .cancel) {}
            } message: {
                Text("Closing now will lose your courier channel. You would need to start the credential exchange over.")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { expanded.toggle() } }
    }

    /// True when the courier protocol is mid-flight — dismissing would lose state.
    private var isActivePhase: Bool {
        switch phase {
        case .calling, .ready, .collecting, .collectFailed: return true
        case .explain, .received, .failed: return false
        }
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
        case .received: return "Credentials Sent."
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
        VStack(alignment: .leading, spacing: 10) {
            if !greeting.isEmpty {
                Text(greeting)
                    .font(.caption)
                    .foregroundStyle(.primary)
            } else {
                Text("In order to come online, **\(operatorName)** needs the credentials below.")
                    .font(.caption)
                    .foregroundStyle(.primary)
            }

            ForEach(missingSecrets, id: \.self) { secret in
                HStack(spacing: 4) {
                    Image(systemName: "key.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text(secret)
                        .font(.caption2.monospaced())
                }
            }

            Text("When you tap Begin, a Secure Courier message will arrive in your Nostr DMs with these fields. Fill them in and reply to securely configure **\(operatorName)**.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            // Check for saved ncred in Keychain
            let savedNcred = effectiveSender.isEmpty ? nil : KeychainService.loadNcred(forPatron: effectiveSender, service: credentialService, operator: operatorNpub)

            if let saved = savedNcred {
                // Saved ncred available — offer one-tap redemption
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "creditcard.fill")
                            .foregroundStyle(.green)
                        Text("Saved credential card found")
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                    }
                    Text(String(saved.prefix(30)) + "...")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button {
                            ncredInput = saved
                            phase = .collecting
                            Task { await redeemNcred() }
                        } label: {
                            Label("Use Saved ncred", systemImage: "checkmark.seal.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.green)

                        Button {
                            phase = .calling
                            Task { await beginCourierFlow() }
                        } label: {
                            Label("New Courier", systemImage: "paperplane")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(8)
                .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else {
                // No saved ncred — normal courier flow
                HStack(spacing: 8) {
                    Button {
                        showNcredField.toggle()
                    } label: {
                        Label("Use ncred", systemImage: "creditcard")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

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

                if showNcredField {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Paste a credential card (ncred1...)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        TextField("ncred1...", text: $ncredInput)
                            .font(.system(size: 10, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                        Button {
                            guard ncredInput.hasPrefix("ncred1") else { return }
                            phase = .collecting
                            Task { await redeemNcred() }
                        } label: {
                            Label("Redeem", systemImage: "checkmark.seal")
                                .font(.caption)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.green)
                        .disabled(!ncredInput.hasPrefix("ncred1"))
                    }
                }
            }
        }
    }

    private var callingContent: some View {
        VStack(spacing: 12) {
            Text("Asking the operator to send a credential form...")
                .font(.caption)
                .foregroundStyle(.secondary)

            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(.orange.opacity(0.3), lineWidth: 1.5)
                        .frame(width: CGFloat(40 + i * 16), height: CGFloat(40 + i * 16))
                        .scaleEffect(phase == .calling ? 1.1 : 1.0)
                        .opacity(phase == .calling ? 0.6 : 0.3)
                        .animation(
                            .easeInOut(duration: 1.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.3),
                            value: phase
                        )
                }
                Image(systemName: "lock.shield.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
            }
            .frame(height: 80)

            ProgressView().controlSize(.small)
        }
    }

    private func readyContent(poison: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Open Messages for **\(operatorName)** and reply to the secure courier form.")
                .font(.caption)
                .foregroundStyle(.primary)

            // Show which npub to look for
            Text(String(operatorNpub.prefix(24)) + "...")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)

            HStack(spacing: 6) {
                Text("Verify phrase:")
                    .font(.caption2)
                    .foregroundStyle(.primary)
                Text("\"\(poison)\"")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
            }
            .padding(8)
            .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))

            Text("Fill in the fields and send your reply. Then tap Collect.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if let onOpenMessages {
                    Button {
                        onOpenMessages()
                    } label: {
                        Label("Open Messages", systemImage: "message.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.blue)
                }

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
        VStack(spacing: 12) {
            Text("Telling the operator to pick up your encrypted reply...")
                .font(.caption)
                .foregroundStyle(.secondary)

            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(.green.opacity(0.3), lineWidth: 1.5)
                        .frame(width: CGFloat(40 + i * 16), height: CGFloat(40 + i * 16))
                        .scaleEffect(phase == .collecting ? 1.1 : 1.0)
                        .opacity(phase == .collecting ? 0.6 : 0.3)
                        .animation(
                            .easeInOut(duration: 1.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.3),
                            value: phase
                        )
                }
                Image(systemName: "envelope.open.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
            }
            .frame(height: 80)

            ProgressView().controlSize(.small)
        }
    }

    private func receivedContent(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Secrets received and stored.", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)

            if !credentialCard.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Credential Card")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Label("Saved to Keychain", systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                        Button {
                            UIPasteboard.general.string = credentialCard
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.green)
                    }
                    Text(credentialCard)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                .padding(8)
                .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))

                Text("Save this ncred to reuse credentials without re-entering them.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            } else {
                Text("The operator is now configured.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !message.isEmpty {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
            Text("Reply not found yet.")
                .font(.caption)
                .foregroundStyle(.orange)

            Text("Make sure you replied to the DM with phrase \"\(poison)\" and all fields filled in.")
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
            Text("Couldn't reach the operator.")
                .font(.caption)
                .foregroundStyle(.red)

            Text(error)
                .font(.caption2)
                .foregroundStyle(.secondary)

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

    private func beginCourierFlow() async {
        do {
            let result = try await MCPService().callRequestCredentialChannel(
                endpointURL: endpointURL,
                senderNpub: effectiveSender,
                service: credentialService
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

    private func collectCredentials(retryCount: Int = 0) async {
        do {
            let result = try await MCPService().callReceiveCredentials(
                endpointURL: endpointURL,
                senderNpub: effectiveSender,
                service: credentialService
            )
            if let data = result.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if json["success"] as? Bool == true {
                    let msg = json["message"] as? String ?? "Credentials stored successfully."
                    if let ncred = json["credential_card"] as? String {
                        credentialCard = ncred
                        // Auto-save ncred to Keychain for future re-use
                        if !effectiveSender.isEmpty {
                            try? KeychainService.saveNcred(
                                ncred,
                                forPatron: effectiveSender,
                                service: credentialService,
                                operator: operatorNpub
                            )
                        }
                        ncredSaved = true
                    }
                    phase = .received(msg)
                } else {
                    let err = json["error"] as? String ?? "No reply found on relays."
                    // Auto-retry once on first failure (often a stale token)
                    if retryCount == 0 {
                        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s
                        await collectCredentials(retryCount: 1)
                        return
                    }
                    phase = .collectFailed(poison: currentPoison, error: err)
                }
            } else {
                phase = .received(result)
            }
        } catch {
            phase = .collectFailed(poison: currentPoison, error: error.localizedDescription)
        }
    }

    private func redeemNcred() async {
        do {
            let result = try await MCPService().callReceiveCredentials(
                endpointURL: endpointURL,
                senderNpub: effectiveSender,
                service: credentialService,
                credentialCard: ncredInput
            )
            if let data = result.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if json["success"] as? Bool == true {
                    let msg = json["message"] as? String ?? "Credentials redeemed from ncred."
                    phase = .received(msg)
                } else {
                    let err = json["error"] as? String ?? "ncred redemption failed."
                    phase = .failed(err)
                }
            } else {
                phase = .received(result)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
