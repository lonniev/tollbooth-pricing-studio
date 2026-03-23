import SwiftUI
import SwiftData

/// Displays a message timeline for a single conversation with a reply composer at the bottom.
struct MessageThreadView: View {
    let conversation: DMConversation
    @Bindable var chatVM: ChatViewModel

    @Query(sort: \Authority.addedAt) private var authorities: [Authority]
    @Query(sort: \Operator.addedAt) private var operators: [Operator]
    @Query(sort: \Patron.addedAt) private var patrons: [Patron]
    @Query(sort: \Contact.addedAt) private var contacts: [Contact]

    @State private var selectedMessageIds: Set<String> = []
    @State private var showDeleteConfirmation = false
    @State private var showClearConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            // Header: sender (me) on left, receiver (them) on right
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(myDisplayName)
                        .font(.headline)
                    if let npub = chatVM.currentIdentity?.npub {
                        Text(String(npub.prefix(16)) + "…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospaced()
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    if let name = displayName(for: conversation.counterpartyPubkeyHex) {
                        Text(name)
                            .font(.headline)
                        Text(conversation.counterpartyDisplayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospaced()
                    } else {
                        Text(conversation.counterpartyDisplayName)
                            .font(.headline)
                            .monospaced()
                    }
                }

                Spacer().frame(width: 0)

                if !selectedMessageIds.isEmpty {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete Selected", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }

                Menu {
                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Label("Clear Stream", systemImage: "trash.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(conversation.messages.enumerated()), id: \.element.id) { index, dm in
                            if shouldShowDateDivider(at: index) {
                                dateDivider(for: dm.createdAt)
                            }

                            MessageBubble(
                                dm: dm,
                                fontName: chatVM.messageFontName,
                                fontSize: chatVM.messageFontSize,
                                isSelected: selectedMessageIds.contains(dm.id),
                                isPending: chatVM.pendingMessageIds.contains(dm.id),
                                onSendReply: { recipientHex, content in
                                    Task {
                                        await chatVM.sendMessage(
                                            to: recipientHex,
                                            content: content
                                        )
                                    }
                                }
                            )
                            .id(dm.id)
                            .contextMenu {
                                Button(role: .destructive) {
                                    Task { await chatVM.requestDeletion(eventIds: [dm.rawEventId]) }
                                } label: {
                                    Label("Delete from Relays", systemImage: "trash")
                                }
                            }
                            .onLongPressGesture {
                                toggleSelection(dm.id)
                            }
                        }
                        // Bottom anchor — ensures last message is never hidden under compose
                        Color.clear.frame(height: 1).id("bottom_anchor")
                    }
                    .padding()
                }
                .onChange(of: conversation.messages.count) {
                    scrollToBottom(proxy)
                }
                .onChange(of: conversation.messages.last?.id) {
                    scrollToBottom(proxy)
                }
                .onAppear {
                    scrollToBottom(proxy)
                }
            }

            Divider()

            // Reply composer
            ReplyComposer(
                fontName: chatVM.messageFontName,
                fontSize: chatVM.messageFontSize
            ) { message in
                Task {
                    await chatVM.sendMessage(
                        to: conversation.counterpartyPubkeyHex,
                        content: message
                    )
                }
            }
        }
        .alert("Delete from Relays?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    await chatVM.requestDeletion(eventIds: Array(selectedMessageIds))
                    selectedMessageIds.removeAll()
                }
            }
        } message: {
            Text("This sends NIP-09 deletion requests. Relays may or may not honor them.")
        }
        .alert("Clear All Messages?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                Task { await chatVM.clearAllMessages() }
            }
        } message: {
            Text("Send deletion requests for all \(conversation.messages.count) messages in this conversation.")
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedMessageIds.contains(id) {
            selectedMessageIds.remove(id)
        } else {
            selectedMessageIds.insert(id)
        }
    }

    /// My display name (the currently selected identity).
    private var myDisplayName: String {
        guard let npub = chatVM.currentIdentity?.npub,
              let hex = try? NostrKeyService.publicKeyHexFromNpub(npub) else {
            return "Me"
        }
        return displayName(for: hex) ?? "Me"
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation { proxy.scrollTo("bottom_anchor", anchor: .bottom) }
    }

    /// Resolve a pubkey hex to a known entity's display name.
    /// Prefers patron aliases (most specific) over operator/authority names.
    private func displayName(for pubkeyHex: String) -> String? {
        let npub = try? NostrKeyService.npubFromHex(pubkeyHex)

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

    // MARK: - Date Dividers

    private func shouldShowDateDivider(at index: Int) -> Bool {
        let messages = conversation.messages
        guard index < messages.count else { return false }
        if index == 0 { return true }
        let calendar = Calendar.current
        return !calendar.isDate(messages[index].createdAt, inSameDayAs: messages[index - 1].createdAt)
    }

    private func dateDivider(for date: Date) -> some View {
        HStack {
            line
            Text(informalDateLabel(for: date))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
            line
        }
        .padding(.vertical, 4)
    }

    private var line: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(height: 1)
    }

    private func informalDateLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else if let sixDaysAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: .now)),
                  date >= sixDaysAgo {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE"
            return formatter.string(from: date)
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE, MMM d"
            return formatter.string(from: date)
        }
    }
}
