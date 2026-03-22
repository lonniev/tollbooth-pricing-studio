import SwiftUI

/// Two-column messaging layout: conversation list on left, message thread on right.
struct ChatView: View {
    @Bindable var chatVM: ChatViewModel
    @State private var showingCompose = false
    @State private var showingFontPicker = false

    private let polling = DMPollingService.shared

    var body: some View {
        Group {
            switch chatVM.state {
            case .idle:
                ContentUnavailableView(
                    "No Messages",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Select an entity with an nsec to view messages.")
                )

            case .loading, .loaded:
                if chatVM.conversations.isEmpty && !chatVM.isLoading {
                    VStack(spacing: 16) {
                        Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("Nostr Secure Messaging")
                            .font(.title3.bold())
                        Text("No conversations yet. Start one below.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button {
                            showingCompose = true
                        } label: {
                            Label("Start a Conversation", systemImage: "square.and.pencil")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if chatVM.conversations.isEmpty {
                    // Loading with no cached conversations yet
                    VStack(spacing: 16) {
                        Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("Nostr Secure Messaging")
                            .font(.title3.bold())
                        Text("Fetching messages from relays\u{2026}")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button {
                            showingCompose = true
                        } label: {
                            Label("Compose While Waiting", systemImage: "square.and.pencil")
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(spacing: 0) {
                        ConversationListView(
                            conversations: chatVM.conversations,
                            selectedId: $chatVM.selectedConversationId
                        )
                        .frame(width: 280)

                        Divider()

                        if let convo = chatVM.selectedConversation {
                            MessageThreadView(
                                conversation: convo,
                                chatVM: chatVM
                            )
                        } else {
                            VStack(spacing: 16) {
                                ContentUnavailableView(
                                    "Select a Conversation",
                                    systemImage: "bubble.left.and.text.bubble.right",
                                    description: Text("Choose a conversation from the list, or start a new one.")
                                )
                                Button {
                                    showingCompose = true
                                } label: {
                                    Label("New Conversation", systemImage: "square.and.pencil")
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }

            case .error(let message):
                ContentUnavailableView {
                    Label("Connection Error", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button {
                        Task { await chatVM.refreshConversations() }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            RelayHeartbeat(polling: polling)
                .padding(8)
        }
        .onChange(of: polling.lastPollAt) {
            // Auto-refresh conversations when polling detects new messages
            if let npub = chatVM.currentIdentity?.npub,
               (polling.unreadCounts[npub] ?? 0) > 0 {
                if chatVM.selectedConversationId != nil {
                    polling.markRead(npub: npub)
                }
                Task { await chatVM.refreshConversations() }
            }
        }
        .onChange(of: chatVM.selectedConversationId) {
            // Clear badge immediately when user selects a conversation
            if chatVM.selectedConversationId != nil,
               let npub = chatVM.currentIdentity?.npub,
               (polling.unreadCounts[npub] ?? 0) > 0 {
                polling.markRead(npub: npub)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingCompose = true
                } label: {
                    Label("New Message", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("composeMessageButton")

                Button {
                    showingFontPicker.toggle()
                } label: {
                    Label("Font", systemImage: "textformat.size")
                }
                .popover(isPresented: $showingFontPicker) {
                    ChatFontPicker(
                        fontName: $chatVM.messageFontName,
                        fontSize: $chatVM.messageFontSize
                    )
                }

                Button {
                    Task { await chatVM.refreshConversations() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .sheet(isPresented: $showingCompose) {
            ComposeMessageSheet(chatVM: chatVM)
        }
        .alert("Relay Fetch Issue", isPresented: .init(
            get: { chatVM.fetchError != nil },
            set: { if !$0 { chatVM.fetchError = nil } }
        )) {
            Button("OK") { chatVM.fetchError = nil }
            Button("Retry") {
                chatVM.fetchError = nil
                Task { await chatVM.refreshConversations() }
            }
        } message: {
            if let error = chatVM.fetchError {
                Text(error)
            }
        }
        .alert("Send Failed", isPresented: .init(
            get: { chatVM.sendError != nil },
            set: { if !$0 { chatVM.sendError = nil } }
        )) {
            Button("OK") { chatVM.sendError = nil }
        } message: {
            if let error = chatVM.sendError {
                Text(error)
            }
        }
    }
}

// MARK: - Pulsing Green Heart

/// Shows a green heart that pulses each time the polling service completes a cycle.
/// If polling stops, the pulse stops — the heart stays static.
private struct RelayHeartbeat: View {
    let polling: DMPollingService
    @State private var scale: CGFloat = 1.0

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 12))
            .foregroundStyle(.green)
            .scaleEffect(scale)
            .onChange(of: polling.lastPollAt) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    scale = 1.4
                }
                withAnimation(.easeInOut(duration: 0.3).delay(0.3)) {
                    scale = 1.0
                }
            }
    }
}
