import DPYCAuthKit
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension NostrConnectURI: @retroactive Identifiable {
    public var id: String { clientPubkey }
}

/// One identity's NIP-46 sign-in: make a bunker:// link, pair a pasted
/// nostrconnect:// link, and list the apps already paired. Each Patron,
/// Operator and Authority edit sheet shows it when Studio holds the nsec.
struct NostrConnectSection: View {
    let npub: String
    @State private var service = NostrConnectService.shared
    @State private var working = false
    @State private var error: String?
    @State private var naming = false
    @State private var newName = ""
    @State private var renaming: NostrConnectSession?
    @State private var rename = ""

    var body: some View {
        Section {
            Button { newName = ""; naming = true } label: {
                Label("Copy a bunker:// link", systemImage: "link.badge.plus")
            }
            if let invite = service.invites.last(where: { $0.signerNpub == npub }) {
                HStack {
                    Label("Copied · until \(invite.expiresAt, style: .time)", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { copy(invite) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Copy again")
                }
            }
            Button { pastePairing() } label: {
                Label("Paste a nostrconnect:// link", systemImage: "doc.on.clipboard")
            }
            .disabled(working)
            ForEach(service.sessions.filter { $0.signerNpub == npub }) { session in
                HStack {
                    Button {
                        rename = session.label ?? ""
                        renaming = session
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(session.displayName, systemImage: "app.connected.to.app.below.fill")
                            Text("Connected \(session.pairedAt, format: .dateTime.month().day().hour().minute())")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.primary)
                    .accessibilityHint("Rename")
                    Spacer()
                    Button { service.disconnect(session) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Disconnect \(session.displayName)")
                }
            }
            if let message = error ?? service.lastError {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Nostr Connect (NIP-46)")
        } footer: {
            Text("""
            Sign in to a Nostr site as this identity, with its key kept here.
            Copy a bunker:// link and paste it into the site's Nostr login.
            Each link works once, for ten minutes.
            Every site you connect gets its own row; tap a name to rename it, ✕ to disconnect.
            Studio asks you before each signature, while it is open.
            """)
        }
        .alert("Which site is this link for?", isPresented: $naming) {
            TextField("Stacker News", text: $newName)
            Button("Copy link") { makeBunkerLink() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The name labels the connection once the site signs in.")
        }
        .alert("Rename connection", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        )) {
            TextField(renaming?.appName ?? "Name", text: $rename)
            Button("Save") {
                if let session = renaming { service.rename(session, to: rename) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func makeBunkerLink() {
        do {
            copy(try service.makeBunkerLink(for: npub, label: newName))
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The pasteboard drops the link when the link itself expires.
    private func copy(_ invite: BunkerInvite) {
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: invite.link]],
            options: [.expirationDate: invite.expiresAt, .localOnly: true]
        )
    }

    private func pastePairing() {
        let uri: NostrConnectURI
        do {
            uri = try NostrConnectURI.parse(UIPasteboard.general.string ?? "")
        } catch {
            self.error = error.localizedDescription
            return
        }
        working = true
        error = nil
        Task {
            do {
                try await service.pair(uri, as: npub)
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

/// Names Studio gives an npub, for labels.
enum IdentityName {
    @MainActor
    static func of(_ npub: String) -> String {
        held().first { $0.npub == npub }?.name ?? String(npub.prefix(16)) + "…"
    }

    /// The name Studio knows *npub* by — any Patron, Operator or Authority it
    /// lists, whether or not it holds the nsec — or nil for a stranger.
    @MainActor
    static func known(_ npub: String) -> String? {
        let context = AppModelContainer.shared.mainContext
        var rows: [(String, String)] = []
        rows += ((try? context.fetch(FetchDescriptor<Patron>())) ?? []).map { ($0.npub, $0.displayName) }
        rows += ((try? context.fetch(FetchDescriptor<Operator>())) ?? []).map { ($0.npub, $0.displayName) }
        rows += ((try? context.fetch(FetchDescriptor<Authority>())) ?? []).map { ($0.npub, $0.displayName) }
        let target = npub.lowercased()
        guard let row = rows.first(where: { $0.0.lowercased() == target }) else { return nil }
        return row.1.isEmpty ? String(npub.prefix(16)) + "…" : row.1
    }

    /// Every Patron, Operator and Authority whose nsec Studio holds.
    @MainActor
    static func held() -> [(npub: String, name: String)] {
        let context = AppModelContainer.shared.mainContext
        var rows: [(String, String)] = []
        rows += ((try? context.fetch(FetchDescriptor<Patron>())) ?? []).map { ($0.npub, $0.displayName) }
        rows += ((try? context.fetch(FetchDescriptor<Operator>())) ?? []).map { ($0.npub, $0.displayName) }
        rows += ((try? context.fetch(FetchDescriptor<Authority>())) ?? []).map { ($0.npub, $0.displayName) }
        var seen = Set<String>()
        return rows
            .filter { !$0.0.isEmpty && seen.insert($0.0).inserted && KeychainService.loadNsec(forNpub: $0.0) != nil }
            .map { (npub: $0.0, name: $0.1.isEmpty ? String($0.0.prefix(16)) + "…" : $0.1) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Pick the identity a site signs in as.
struct NostrConnectPairSheet: View {
    @Environment(\.dismiss) private var dismiss
    let uri: NostrConnectURI
    @State private var identities: [(npub: String, name: String)] = []
    @State private var chosen: String = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("App") {
                    Text(uri.name ?? "Unnamed app")
                    if let url = uri.url { Text(url).foregroundStyle(.secondary) }
                }
                Section("Sign in as") {
                    if identities.isEmpty {
                        Text("Studio holds no signing key yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Identity", selection: $chosen) {
                            ForEach(identities, id: \.npub) { Text($0.name).tag($0.npub) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        NostrConnectService.shared.pairing = nil
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") { connect() }
                        .disabled(chosen.isEmpty || working)
                }
            }
            .task {
                identities = IdentityName.held()
                if chosen.isEmpty { chosen = identities.first?.npub ?? "" }
            }
        }
    }

    private func connect() {
        working = true
        error = nil
        Task {
            do {
                try await NostrConnectService.shared.pair(uri, as: chosen)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

/// Approve or reject one request from a connected app.
struct NostrConnectApprovalSheet: View {
    @Environment(\.dismiss) private var dismiss
    let approval: NostrConnectApproval

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("App", value: approval.session.displayName)
                    LabeledContent("As", value: IdentityName.of(approval.session.signerNpub))
                }
                Section(approval.title) {
                    Text(approval.detail)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Approve?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reject", role: .destructive) { decide(approve: false) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Approve") { decide(approve: true) }
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private func decide(approve: Bool) {
        NostrConnectService.shared.resolve(approval, approve: approve)
        dismiss()
    }
}

/// Shows the pairing and approval sheets in a window of their own above the
/// app, so they appear whatever sheet is already open (Settings → Connected
/// Apps is itself a sheet, and a second sheet cannot rise from the root).
@MainActor
final class NostrConnectPresenter {
    static let shared = NostrConnectPresenter()
    private var window: UIWindow?
    /// The app window that was key before the prompt, made key again after.
    private weak var previousKey: UIWindow?

    private init() {}

    /// Open the window when a prompt is waiting; close it when none is.
    func refresh() {
        let service = NostrConnectService.shared
        let needed = service.pairing != nil || !service.pending.isEmpty
        if needed, window == nil {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
            else { return }
            let host = UIHostingController(rootView: NostrConnectPrompts())
            host.view.backgroundColor = .clear
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.backgroundColor = .clear
            window.rootViewController = host
            previousKey = scene.keyWindow
            window.makeKeyAndVisible()
            self.window = window
        } else if !needed, let window {
            window.isHidden = true
            self.window = nil
            previousKey?.makeKey()
        }
    }
}

/// The prompt window's content: nothing but the two sheets.
private struct NostrConnectPrompts: View {
    @State private var service = NostrConnectService.shared
    /// Sheets present only after the host is on screen.
    @State private var ready = false

    var body: some View {
        Color.clear
            .ignoresSafeArea()
            .sheet(item: Binding(get: { ready ? service.pairing : nil },
                                 set: { service.pairing = $0 })) { uri in
                NostrConnectPairSheet(uri: uri)
            }
            .sheet(item: Binding(get: { ready && service.pairing == nil ? service.pending.first : nil },
                                 set: { _ in })) { approval in
                NostrConnectApprovalSheet(approval: approval)
            }
            .task { ready = true }
    }
}
