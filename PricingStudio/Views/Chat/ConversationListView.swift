import SwiftUI

/// Displays the list of conversation partners, sorted by recency.
struct ConversationListView: View {
    let conversations: [DMConversation]
    @Binding var selectedId: String?

    var body: some View {
        List(conversations, selection: $selectedId) { convo in
            VStack(alignment: .leading, spacing: 4) {
                Text(convo.counterpartyDisplayName)
                    .font(.headline)
                    .monospaced()
                    .lineLimit(1)

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
}
