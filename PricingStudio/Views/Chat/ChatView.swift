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

            case .loading:
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Fetching messages from relays...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .loaded:
                if chatVM.conversations.isEmpty {
                    ContentUnavailableView(
                        "No Conversations",
                        systemImage: "bubble.left",
                        description: Text("No DMs found. Tap + to compose a new message.")
                    )
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
                            ContentUnavailableView(
                                "Select a Conversation",
                                systemImage: "bubble.left.and.text.bubble.right",
                                description: Text("Choose a conversation from the list.")
                            )
                        }
                    }
                }

            case .error(let message):
                ContentUnavailableView(
                    "Error",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
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
    }
}
