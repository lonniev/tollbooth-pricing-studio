import SwiftUI

/// Displays a message timeline for a single conversation with a reply composer at the bottom.
struct MessageThreadView: View {
    let conversation: DMConversation
    @Bindable var chatVM: ChatViewModel

    @State private var selectedMessageIds: Set<String> = []
    @State private var showDeleteConfirmation = false
    @State private var showClearConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(conversation.counterpartyDisplayName)
                    .font(.headline)
                    .monospaced()

                Spacer()

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
                        ForEach(conversation.messages) { dm in
                            MessageBubble(
                                dm: dm,
                                fontName: chatVM.messageFontName,
                                fontSize: chatVM.messageFontSize,
                                isSelected: selectedMessageIds.contains(dm.id)
                            )
                            .id(dm.id)
                            .onLongPressGesture {
                                toggleSelection(dm.id)
                            }
                        }
                    }
                    .padding()
                }
                .onChange(of: conversation.messages.count) {
                    if let lastId = conversation.messages.last?.id {
                        withAnimation {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    if let lastId = conversation.messages.last?.id {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
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
}
