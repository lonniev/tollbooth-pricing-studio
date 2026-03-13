import SwiftUI

struct AssistantPanelView: View {
    @Bindable var assistantVM: AssistantViewModel
    let context: AppContext
    @State private var inputText = ""
    @State private var showingAPIKeySheet = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            messageList

            Divider()

            inputBar
        }
        .frame(minWidth: 300, idealWidth: 360)
        .sheet(isPresented: $showingAPIKeySheet) {
            AssistantAPIKeySheet()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack {
            Label("AI Assistant", systemImage: "sparkles")
                .font(.headline)

            Spacer()

            Button {
                assistantVM.clear()
            } label: {
                Label("Clear", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .disabled(assistantVM.messages.isEmpty)

            Button {
                showingAPIKeySheet = true
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Message List

    @ViewBuilder
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if assistantVM.messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(assistantVM.messages) { message in
                            assistantBubble(message)
                                .id(message.id)
                        }
                    }
                }
                .padding()
            }
            .onChange(of: assistantVM.messages.last?.content) { _, _ in
                if let lastId = assistantVM.messages.last?.id {
                    withAnimation {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Ask about tools, pricing, balances, or DPYC architecture")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    @ViewBuilder
    private func assistantBubble(_ message: AssistantMessage) -> some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.content.isEmpty && message.isStreaming ? "..." : message.content)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(message.role == .user
                        ? Color.accentColor.opacity(0.15)
                        : Color(.tertiarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                if message.isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }

    // MARK: - Input Bar

    @ViewBuilder
    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask about this entity...", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .onSubmit { send() }

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || assistantVM.isStreaming)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        assistantVM.sendUserMessage(text, context: context)
    }
}
