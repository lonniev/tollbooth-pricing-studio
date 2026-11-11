import DPYCAuthKit
import SwiftData
import SwiftUI
import UIKit

extension NostrConnectURI: @retroactive Identifiable {
    public var id: String { clientPubkey }
}

/// Apps that sign in with one of Studio's identities over NIP-46.
struct ConnectedAppsView: View {
    @State private var service = NostrConnectService.shared

    var body: some View {
        Form {
            Section {
                Button {
                    service.open(UIPasteboard.general.string ?? "")
                } label: {
                    Label("Paste a nostrconnect:// link", systemImage: "doc.on.clipboard")
                }
                if let error = service.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("Copy the link a site shows under Continue with Nostr, or tap it to open Studio. Keep Studio open while you sign in.")
            }

            if !service.sessions.isEmpty {
                Section("Connected") {
                    ForEach(service.sessions) { session in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.displayName)
                            Text(IdentityName.of(session.signerNpub))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("Disconnect", role: .destructive) { service.disconnect(session) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Connected Apps")
    }
}

/// Names Studio gives an npub, for labels.
enum IdentityName {
    @MainActor
    static func of(_ npub: String) -> String {
        held().first { $0.npub == npub }?.name ?? String(npub.prefix(16)) + "…"
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

/// The pairing and approval sheets, shown over whatever screen is up.
private struct NostrConnectSheets: ViewModifier {
    @State private var service = NostrConnectService.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: $service.pairing) { uri in
                NostrConnectPairSheet(uri: uri)
            }
            .sheet(item: Binding(get: { service.pending.first }, set: { _ in })) { approval in
                NostrConnectApprovalSheet(approval: approval)
            }
    }
}

extension View {
    func nostrConnectSheets() -> some View { modifier(NostrConnectSheets()) }
}
