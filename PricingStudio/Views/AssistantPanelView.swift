import SwiftUI

struct AssistantPanelView: View {
    @Bindable var assistantVM: AssistantViewModel
    let context: AppContext
    var onToggleFullScreen: (() -> Void)?
    var isFullScreen: Bool = false
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
        .frame(minWidth: 300, idealWidth: isFullScreen ? .infinity : 360)
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

            if let onToggleFullScreen {
                Button {
                    onToggleFullScreen()
                } label: {
                    Label(
                        isFullScreen ? "Collapse" : "Expand",
                        systemImage: isFullScreen
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right"
                    )
                    .labelStyle(.iconOnly)
                }
            }

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
        if KeychainService.loadAnthropicAPIKey() == nil {
            VStack(spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("API Key Required")
                    .font(.headline)
                Text("An Anthropic API key is needed to use the AI assistant. You can get one from the Anthropic console.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    showingAPIKeySheet = true
                } label: {
                    Label("Set Up API Key", systemImage: "gearshape")
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        } else {
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
    }

    @ViewBuilder
    private func assistantBubble(_ message: AssistantMessage) -> some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if message.role == .assistant {
                    markdownView(for: message.content.isEmpty && message.isStreaming ? "..." : message.content)
                        .textSelection(.enabled)
                        .padding(10)
                        .background(Color(.tertiarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Text(message.content)
                        .textSelection(.enabled)
                        .padding(10)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                if message.isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }

    // MARK: - Markdown Rendering

    @ViewBuilder
    private func markdownView(for text: String) -> some View {
        let segments = parseMarkdownSegments(text)
        let hasBlocks = segments.contains(where: { $0.isCodeBlock }) || containsBlockMarkdown(text)
        if hasBlocks {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    if segment.isCodeBlock {
                        codeBlockView(segment.content, language: segment.language)
                    } else {
                        renderBlockText(segment.content)
                    }
                }
            }
        } else {
            Text(markdownAttributed(text))
        }
    }

    private func containsBlockMarkdown(_ text: String) -> Bool {
        text.components(separatedBy: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ")
                || trimmed.hasPrefix("# ")
                || trimmed.hasPrefix("## ")
                || trimmed.hasPrefix("### ")
                || trimmed == "---" || trimmed == "***" || trimmed == "___"
                || trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil
        }
    }

    @ViewBuilder
    private func renderBlockText(_ text: String) -> some View {
        let lines = text.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                    Divider()
                        .padding(.vertical, 4)
                } else if let heading = parseHeading(trimmed) {
                    Text(markdownAttributed(heading.text))
                        .font(heading.font)
                        .padding(.top, heading.level == 1 ? 8 : 4)
                } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    HStack(alignment: .top, spacing: 6) {
                        Text("\u{2022}")
                            .font(.body)
                        Text(markdownAttributed(String(trimmed.dropFirst(2))))
                    }
                } else if let range = trimmed.range(of: #"^(\d+)\.\s"#, options: .regularExpression) {
                    let prefix = String(trimmed[range])
                    let rest = String(trimmed[range.upperBound...])
                    HStack(alignment: .top, spacing: 4) {
                        Text(prefix)
                            .foregroundStyle(.secondary)
                        Text(markdownAttributed(rest))
                    }
                } else if !trimmed.isEmpty {
                    Text(markdownAttributed(trimmed))
                }
            }
        }
    }

    private struct HeadingInfo {
        let level: Int
        let text: String
        var font: Font {
            switch level {
            case 1: return .title2.bold()
            case 2: return .title3.bold()
            case 3: return .headline
            default: return .subheadline.bold()
            }
        }
    }

    private func parseHeading(_ line: String) -> HeadingInfo? {
        if line.hasPrefix("### ") {
            return HeadingInfo(level: 3, text: String(line.dropFirst(4)))
        } else if line.hasPrefix("## ") {
            return HeadingInfo(level: 2, text: String(line.dropFirst(3)))
        } else if line.hasPrefix("# ") {
            return HeadingInfo(level: 1, text: String(line.dropFirst(2)))
        }
        return nil
    }

    private func markdownAttributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    @ViewBuilder
    private func codeBlockView(_ code: String, language: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let lang = language, !lang.isEmpty {
                Text(lang)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
            }
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Markdown Segment Parsing

    private struct MarkdownSegment {
        let content: String
        let isCodeBlock: Bool
        let language: String?
    }

    private func parseMarkdownSegments(_ text: String) -> [MarkdownSegment] {
        var segments: [MarkdownSegment] = []
        let lines = text.components(separatedBy: "\n")
        var currentText: [String] = []
        var codeLines: [String] = []
        var inCodeBlock = false
        var codeLang: String?

        for line in lines {
            if line.hasPrefix("```") && !inCodeBlock {
                // Start of code block — flush accumulated text
                let accumulated = currentText.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !accumulated.isEmpty {
                    segments.append(MarkdownSegment(content: accumulated, isCodeBlock: false, language: nil))
                }
                currentText = []
                inCodeBlock = true
                codeLang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if codeLang?.isEmpty == true { codeLang = nil }
            } else if line.hasPrefix("```") && inCodeBlock {
                // End of code block
                let code = codeLines.joined(separator: "\n")
                segments.append(MarkdownSegment(content: code, isCodeBlock: true, language: codeLang))
                codeLines = []
                inCodeBlock = false
                codeLang = nil
            } else if inCodeBlock {
                codeLines.append(line)
            } else {
                currentText.append(line)
            }
        }

        // Flush remaining
        if inCodeBlock {
            // Unterminated code block — render as code anyway
            let code = codeLines.joined(separator: "\n")
            segments.append(MarkdownSegment(content: code, isCodeBlock: true, language: codeLang))
        } else {
            let accumulated = currentText.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !accumulated.isEmpty {
                segments.append(MarkdownSegment(content: accumulated, isCodeBlock: false, language: nil))
            }
        }

        return segments
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
