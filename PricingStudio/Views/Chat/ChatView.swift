import SwiftUI

/// Messaging layout. Regular width is two columns — conversation list beside
/// the thread. Compact width is a single column that shows the list, then the
/// selected thread (with a back affordance), since 280pt of list beside a
/// thread doesn't fit a phone.
struct ChatView: View {
    @Bindable var chatVM: ChatViewModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showingCompose = false
    @State private var showingFontPicker = false

    private let polling = DMPollingService.shared
    private var isCompact: Bool { sizeClass == .compact }

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
                messageSplit(showLoading: true)

            case .error(let message):
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi.exclamationmark")
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            Task { await chatVM.refreshConversations() }
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                    // Still show conversations even in the error state.
                    messageSplit(showLoading: false)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            RelayHeartbeat(polling: polling)
                .padding(8)
        }
        .onAppear {
            // Clear badge when user navigates to Messages tab
            if let npub = chatVM.currentIdentity?.npub {
                polling.markRead(npub: npub)
            }
        }
        .onChange(of: polling.lastPollAt) {
            // Auto-refresh conversations when polling detects new messages
            if let npub = chatVM.currentIdentity?.npub,
               (polling.unreadCounts[npub] ?? 0) > 0 {
                polling.markRead(npub: npub)
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

    // MARK: - Layout

    /// The list+thread composition, rendered per format. Compact is one column
    /// (list, or the selected thread); regular is the fixed two-column split.
    @ViewBuilder
    private func messageSplit(showLoading: Bool) -> some View {
        if isCompact {
            if let convo = chatVM.selectedConversation {
                threadColumn(convo)
            } else {
                conversationColumn(showLoading: showLoading)
            }
        } else {
            HStack(spacing: 0) {
                conversationColumn(showLoading: showLoading)
                    .frame(width: 280)
                Divider()
                if let convo = chatVM.selectedConversation {
                    MessageThreadView(conversation: convo, chatVM: chatVM)
                } else {
                    selectPlaceholder
                }
            }
        }
    }

    private func conversationColumn(showLoading: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Conversations")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showingCompose = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            ConversationListView(
                conversations: chatVM.conversations,
                selectedId: $chatVM.selectedConversationId,
                currentIdentityPubHex: chatVM.currentIdentity?.publicKeyHex
            )

            if showLoading && chatVM.isLoading {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("Fetching…").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// Compact-only: the thread with a back affordance to return to the list.
    private func threadColumn(_ convo: DMConversation) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    chatVM.selectedConversationId = nil
                } label: {
                    Label("Conversations", systemImage: "chevron.left")
                        .font(.subheadline)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            MessageThreadView(conversation: convo, chatVM: chatVM)
        }
    }

    private var selectPlaceholder: some View {
        ContentUnavailableView(
            "Select a Conversation",
            systemImage: "bubble.left.and.text.bubble.right",
            description: Text("Choose a conversation from the list, or start a new one.")
        )
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
