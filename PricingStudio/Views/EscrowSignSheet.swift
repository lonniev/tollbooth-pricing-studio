import DPYCAuthKit
import SwiftUI

/// "Sign this…": what a job's escrow waits on from one of your npubs, opened by
/// a site's link. Each move reads in plain words, beside the operator's host;
/// Sign asks for Face ID, then signs the message Studio rebuilt and checked.
struct EscrowSignSheet: View {
    let link: EscrowLink
    @Environment(\.dismiss) private var dismiss
    @State private var reading: EscrowSigningService.Reading?
    @State private var problem = ""
    @State private var busy = false
    @State private var signed: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Job", value: reading?.title ?? link.taskId)
                    LabeledContent("Task Booth", value: link.mcp.host ?? "")
                    if let mint = reading?.mint, !mint.isEmpty { LabeledContent("Mint", value: URL(string: mint)?.host ?? mint) }
                    LabeledContent("As", value: shortNpub(link.npub))
                }

                if let reading {
                    Section("Waiting on you") {
                        if reading.pending.isEmpty {
                            Text(signed.isEmpty ? "Nothing in this escrow waits on your signature." : "Signed. The site shows it on its next look.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(reading.pending) { pending in
                            row(pending)
                        }
                    }
                } else if problem.isEmpty {
                    Section { ProgressView("Reading the escrow…") }
                }

                if !problem.isEmpty {
                    Section { Text(problem).foregroundStyle(.red) }
                }

                Section {
                    Text("Studio rebuilt each message and checked that it only moves sats locked to your key. Who receives each share is the operator's word.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Sign this…")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
        }
    }

    private func row(_ pending: EscrowSigningService.Pending) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            Text(describe(pending.item))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Task { await sign(pending) }
            } label: {
                Label(signed.contains(pending.id) ? "Signed" : "Sign", systemImage: signed.contains(pending.id) ? "checkmark.seal" : "signature")
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || signed.contains(pending.id))
            .accessibilityIdentifier("escrowSignButton_\(pending.item.what.rawValue)")
        }
        .padding(.vertical, 4)
    }

    private func describe(_ item: EscrowSigning.Signable) -> String {
        switch item.what {
        case .fund:
            return "Lock \(item.sats ?? 0) sats in escrow."
        case .proposal:
            return "Agree: \(item.to_performer ?? 0) sats to the professional, \(item.to_purchaser ?? 0) back to the client."
        case .collect:
            return "Pay \(item.sats ?? 0) sats to your payout address. Up to \(item.fee_reserve ?? 0) sats go to Lightning fees."
        }
    }

    private func shortNpub(_ npub: String) -> String { "\(npub.prefix(12))…\(npub.suffix(6))" }

    private func load() async {
        problem = ""
        do {
            reading = try await EscrowSigningService.read(link)
        } catch {
            problem = error.localizedDescription
        }
    }

    private func sign(_ pending: EscrowSigningService.Pending) async {
        busy = true
        problem = ""
        defer { busy = false }
        do {
            try await EscrowSigningService.sign(pending, link: link, reason: describe(pending.item))
            signed.insert(pending.id)
            await load()
        } catch {
            problem = error.localizedDescription
        }
    }
}
