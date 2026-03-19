import SwiftUI
import SwiftData

/// Displays the list of conversation partners, sorted by recency.
struct ConversationListView: View {
    let conversations: [DMConversation]
    @Binding var selectedId: String?

    @Query(sort: \Authority.addedAt) private var authorities: [Authority]
    @Query(sort: \Operator.addedAt) private var operators: [Operator]
    @Query(sort: \Patron.addedAt) private var patrons: [Patron]
    @Query(sort: \Contact.addedAt) private var contacts: [Contact]

    var body: some View {
        List(conversations, selection: $selectedId) { convo in
            VStack(alignment: .leading, spacing: 4) {
                if let name = displayName(for: convo.counterpartyPubkeyHex) {
                    Text(name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(convo.counterpartyDisplayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospaced()
                        .lineLimit(1)
                } else {
                    Text(convo.counterpartyDisplayName)
                        .font(.headline)
                        .monospaced()
                        .lineLimit(1)
                }

                if let latest = convo.latestMessage {
                    Text(latest.content)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    Text(latest.createdAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
            .tag(convo.id)
        }
        .listStyle(.sidebar)
    }

    /// Resolve a pubkey hex to a known entity's display name.
    private func displayName(for pubkeyHex: String) -> String? {
        let npub = try? NostrKeyService.npubFromHex(pubkeyHex)

        for auth in authorities where auth.npub == npub {
            return auth.displayName
        }
        for op in operators where op.npub == npub {
            return op.displayName
        }
        for patron in patrons where patron.npub == npub {
            return patron.displayName
        }
        for contact in contacts where contact.npub == npub {
            return contact.displayName
        }
        return nil
    }
}
