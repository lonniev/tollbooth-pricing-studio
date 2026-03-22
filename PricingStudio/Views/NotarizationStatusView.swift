import SwiftUI

/// Shows the most recent Bitcoin notarization status for an operator.
/// Tapping reveals a detail sheet with the full OTS crypto info.
struct NotarizationStatusView: View {
    let operatorNpub: String
    let endpointURL: String

    @State private var status: NotarizationStatus = .idle
    @State private var showingDetail = false

    enum NotarizationStatus {
        case idle
        case loading
        case loaded(NotarizationRecord)
        case none // No notarizations exist
        case error(String)
    }

    struct NotarizationRecord {
        let notarizationId: String
        let rootHash: String
        let leafCount: Int
        let status: String
        let createdAt: String
        let receiptCount: Int
        let confirmedAt: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch status {
            case .idle:
                EmptyView()
                    .onAppear { Task { await loadStatus() } }
            case .loading:
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Checking notarization…").font(.caption2).foregroundStyle(.secondary)
                }
            case .loaded(let record):
                Button { showingDetail = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: record.status == "confirmed" ? "checkmark.seal.fill" : "seal.fill")
                            .foregroundStyle(record.status == "confirmed" ? .green : .orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Bitcoin Notarized")
                                .font(.caption2.bold())
                            Text("\(record.leafCount) balances · \(relativeDate(record.createdAt))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            case .none:
                HStack(spacing: 4) {
                    Image(systemName: "seal")
                        .foregroundStyle(.tertiary)
                    Text("No notarizations yet")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            case .error:
                EmptyView() // Silent — notarization is informational
            }
        }
        .sheet(isPresented: $showingDetail) {
            if case .loaded(let record) = status {
                NotarizationDetailSheet(record: record)
            }
        }
    }

    private func loadStatus() async {
        status = .loading
        let mcpService = MCPService()
        do {
            guard let url = URL(string: endpointURL) else {
                status = .error("Invalid URL")
                return
            }
            let response = try await mcpService.callToolGeneric(
                endpointURL: url,
                bearerToken: "",
                toolName: "list_notarizations"
            )
            if let data = response.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let notarizations = json["notarizations"] as? [[String: Any]],
               let first = notarizations.first {
                status = .loaded(NotarizationRecord(
                    notarizationId: first["notarization_id"] as? String ?? first["anchor_id"] as? String ?? "?",
                    rootHash: first["root_hash"] as? String ?? "?",
                    leafCount: first["leaf_count"] as? Int ?? 0,
                    status: first["status"] as? String ?? "unknown",
                    createdAt: first["created_at"] as? String ?? "?",
                    receiptCount: first["receipt_count"] as? Int ?? 0,
                    confirmedAt: first["confirmed_at"] as? String
                ))
            } else {
                status = .none
            }
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    private func relativeDate(_ iso: String) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fmt.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return iso }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .abbreviated
        return rel.localizedString(for: date, relativeTo: .now)
    }
}

// MARK: - Crypto Detail Sheet

private struct NotarizationDetailSheet: View {
    let record: NotarizationStatusView.NotarizationRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Bitcoin Notarization") {
                    LabeledContent("Status") {
                        HStack(spacing: 4) {
                            Image(systemName: record.status == "confirmed" ? "checkmark.seal.fill" : "seal.fill")
                                .foregroundStyle(record.status == "confirmed" ? .green : .orange)
                            Text(record.status.capitalized)
                                .foregroundStyle(record.status == "confirmed" ? .green : .orange)
                        }
                    }
                    LabeledContent("Balances Covered", value: "\(record.leafCount)")
                    LabeledContent("OTS Calendars", value: "\(record.receiptCount)")
                    LabeledContent("Created", value: record.createdAt)
                    if let confirmed = record.confirmedAt {
                        LabeledContent("Bitcoin Confirmed", value: confirmed)
                    }
                }

                Section("Cryptographic Proof") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Merkle Root Hash")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(record.rootHash)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Notarization ID")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(record.notarizationId)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                Section("How This Works") {
                    Text("""
                    This operator periodically takes a SHA-256 Merkle tree \
                    of all patron balances and submits the root hash to \
                    Bitcoin via OpenTimestamps (OTS) calendar servers.

                    Once confirmed in a Bitcoin block, this creates an \
                    immutable proof that these exact balances existed at \
                    this exact time — anchored to the strongest proof-of-work \
                    chain in existence.

                    Any patron can independently verify their balance was \
                    included by requesting a Merkle inclusion proof and \
                    walking the sibling hashes up to the root.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Bitcoin Notarization")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
