import SwiftUI

/// Two-column messaging layout: conversation list on left, message thread on right.
struct ChatView: View {
    @Bindable var chatVM: ChatViewModel
    @State private var showingCompose = false
    @State private var showingFontPicker = false

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
                    ContentUnavailableView {
                        Label("Nostr Secure Messaging", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                    } description: {
                        Text("Send encrypted DMs via Nostr relays. Tap the compose button to start a conversation, or refresh to poll relays for new arrivals.")
                    } actions: {
                        Button {
                            showingCompose = true
                        } label: {
                            Text("Start a Conversation")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if chatVM.conversations.isEmpty {
                    // Loading with no cached conversations yet — show welcome + spinner
                    VStack(spacing: 16) {
                        Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("Nostr Secure Messaging")
                            .font(.title3.bold())
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Polling relays\u{2026}")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text("You can compose a message while relays are polled.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ZStack(alignment: .top) {
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
                                ContentUnavailableView(
                                    "Select a Conversation",
                                    systemImage: "bubble.left.and.text.bubble.right",
                                    description: Text("Choose a conversation from the list.")
                                )
                            }
                        }

                        if chatVM.isLoading {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("Polling relays\u{2026}")
                                    .font(.caption2)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.top, 4)
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
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingCompose = true
                } label: {
                    Label("New Message", systemImage: "square.and.pencil")
                }

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
