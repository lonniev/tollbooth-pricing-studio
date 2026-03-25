import SwiftUI

/// Generates a fresh Nostr keypair and displays it once.
/// Nothing is saved — the user must copy the values themselves.
struct KeypairGeneratorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var npub: String = ""
    @State private var nsec: String = ""
    @State private var generated = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if !generated {
                    VStack(spacing: 16) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.orange)

                        Text("Generate Nostr Keypair")
                            .font(.title2.bold())

                        Text("This will create a new Nostr identity — a public key (npub) and a private key (nsec). The private key is shown once and is not saved anywhere.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 400)

                        Button {
                            generateKeypair()
                        } label: {
                            Label("Generate", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Public Key (npub)")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Text(npub)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(10)
                                .background(.quaternary.opacity(0.3))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Private Key (nsec)")
                                    .font(.caption.bold())
                                    .foregroundStyle(.red)
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            Text(nsec)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(10)
                                .background(.red.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Label("Copy both values now — they will not be shown again", systemImage: "doc.on.doc")
                            Label("Never share your nsec — it controls this identity", systemImage: "lock.fill")
                            Label("Your npub is safe to share — it's your public identity", systemImage: "person.fill")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 450)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Nostr Keypair")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func generateKeypair() {
        guard let pair = try? NostrKeyService.generateKeyPair() else { return }
        npub = pair.npub
        nsec = pair.nsec
        generated = true
    }
}
