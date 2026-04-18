import SwiftUI
import SwiftData

/// Displays the list of conversation partners, sorted by recency.
/// Supports pinning one conversation and collapsing the rest.
struct ConversationListView: View {
    let conversations: [DMConversation]
    @Binding var selectedId: String?

    @Query(sort: \Authority.addedAt) private var authorities: [Authority]
    @Query(sort: \Operator.addedAt) private var operators: [Operator]
    @Query(sort: \Patron.addedAt) private var patrons: [Patron]
    @Query(sort: \Contact.addedAt) private var contacts: [Contact]

    /// Current identity's pubkey hex — used to filter self-conversations at the view level
    var currentIdentityPubHex: String?

    @State private var pinnedId: String?
    @State private var othersExpanded = true

    private var filtered: [DMConversation] {
        let base = currentIdentityPubHex != nil
            ? conversations.filter { $0.counterpartyPubkeyHex != currentIdentityPubHex }
            : conversations
        return base
    }

    private var pinnedConvo: DMConversation? {
        guard let id = pinnedId else { return nil }
        return filtered.first { $0.id == id }
    }

    private var otherConvos: [DMConversation] {
        guard let id = pinnedId else { return filtered }
        return filtered.filter { $0.id != id }
    }

    var body: some View {
        List(selection: $selectedId) {
            if let pinned = pinnedConvo {
                Section {
                    conversationRow(pinned)
                        .contextMenu { unpinButton(pinned) }
                } header: {
                    HStack {
                        Label("Pinned", systemImage: "pin.fill")
                            .font(.caption2)
                        Spacer()
                    }
                }
            }

            Section(isExpanded: pinnedId != nil ? $othersExpanded : .constant(true)) {
                ForEach(otherConvos) { convo in
                    conversationRow(convo)
                        .contextMenu { pinButton(convo) }
                }
            } header: {
                if pinnedId != nil {
                    HStack {
                        Label(othersExpanded ? "Others" : "\(otherConvos.count) more", systemImage: "bubble.left.and.bubble.right")
                            .font(.caption2)
                        Spacer()
                        Button {
                            withAnimation { othersExpanded.toggle() }
                        } label: {
                            Image(systemName: othersExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func conversationRow(_ convo: DMConversation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let name = displayName(for: convo.counterpartyPubkeyHex) {
                HStack(spacing: 4) {
                    Text(name)
                        .font(.headline)
                        .lineLimit(1)
                    if let npub = convo.counterpartyNpub,
                       (DMPollingService.shared.unreadCounts[npub] ?? 0) > 0 {
                        Circle()
                            .fill(.blue)
                            .frame(width: 8, height: 8)
                    }
                }
                Text(convo.counterpartyDisplayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospaced()
                    .lineLimit(1)
            } else {
                HStack(spacing: 4) {
                    Text(convo.counterpartyDisplayName)
                        .font(.headline)
                        .monospaced()
                        .lineLimit(1)
                    if let npub = convo.counterpartyNpub,
                       (DMPollingService.shared.unreadCounts[npub] ?? 0) > 0 {
                        Circle()
                            .fill(.blue)
                            .frame(width: 8, height: 8)
                    }
                }
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

    private func pinButton(_ convo: DMConversation) -> some View {
        Button {
            withAnimation {
                pinnedId = convo.id
                selectedId = convo.id
                othersExpanded = false
            }
        } label: {
            Label("Pin Conversation", systemImage: "pin")
        }
    }

    private func unpinButton(_ convo: DMConversation) -> some View {
        Button {
            withAnimation {
                pinnedId = nil
                othersExpanded = true
            }
        } label: {
            Label("Unpin", systemImage: "pin.slash")
        }
    }

    /// Resolve a pubkey hex to a known entity's display name.
    /// Prefers patron aliases (most specific) over operator/authority names.
    private func displayName(for pubkeyHex: String) -> String? {
        let npub = try? NostrKeyService.npubFromHex(pubkeyHex)

        // Patron aliases first — they carry the most specific context
        // (e.g., "Lonnie @ Schwab" vs generic "Schwab")
        for patron in patrons where patron.npub == npub {
            return patron.displayName
        }
        for contact in contacts where contact.npub == npub {
            return contact.displayName
        }
        for op in operators where op.npub == npub {
            return op.displayName
        }
        for auth in authorities where auth.npub == npub {
            return auth.displayName
        }
        return nil
    }
}
