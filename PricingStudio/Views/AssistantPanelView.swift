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
        let hasBlocks = segments.contains(where: { $0.isCodeBlock || $0.isTable }) || containsBlockMarkdown(text)
        if hasBlocks {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment.kind {
                    case .code(let language):
                        codeBlockView(segment.content, language: language)
                    case .table(let header, let rows):
                        tableView(header: header, rows: rows)
                    case .text:
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
                || trimmed.hasPrefix("|")
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

    @ViewBuilder
    private func tableView(header: [String], rows: [[String]]) -> some View {
        let colCount = header.count
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Header row
                HStack(spacing: 0) {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(markdownAttributed(cell))
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(minWidth: 60, alignment: .leading)
                    }
                }
                Divider()
                // Data rows
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                    HStack(spacing: 0) {
                        ForEach(0..<colCount, id: \.self) { colIdx in
                            Text(markdownAttributed(colIdx < row.count ? row[colIdx] : ""))
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .frame(minWidth: 60, alignment: .leading)
                        }
                    }
                    if rowIdx < rows.count - 1 {
                        Divider().opacity(0.5)
                    }
                }
            }
            .textSelection(.enabled)
        }
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Markdown Segment Parsing

    private enum SegmentKind {
        case text
        case code(language: String?)
        case table(header: [String], rows: [[String]])
    }

    private struct MarkdownSegment {
        let content: String
        let kind: SegmentKind

        var isCodeBlock: Bool {
            if case .code = kind { return true }
            return false
        }
        var language: String? {
            if case .code(let lang) = kind { return lang }
            return nil
        }
        var isTable: Bool {
            if case .table = kind { return true }
            return false
        }
    }

    private func parseMarkdownSegments(_ text: String) -> [MarkdownSegment] {
        var segments: [MarkdownSegment] = []
        let lines = text.components(separatedBy: "\n")
        var currentText: [String] = []
        var codeLines: [String] = []
        var inCodeBlock = false
        var codeLang: String?
        var tableLines: [String] = []

        func flushText() {
            let accumulated = currentText.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !accumulated.isEmpty {
                segments.append(MarkdownSegment(content: accumulated, kind: .text))
            }
            currentText = []
        }

        func flushTable() {
            guard tableLines.count >= 2 else {
                // Not enough lines for a real table — treat as text
                currentText.append(contentsOf: tableLines)
                tableLines = []
                return
            }
            let parsed = parseTableLines(tableLines)
            if let parsed {
                segments.append(MarkdownSegment(
                    content: tableLines.joined(separator: "\n"),
                    kind: .table(header: parsed.header, rows: parsed.rows)
                ))
            } else {
                currentText.append(contentsOf: tableLines)
            }
            tableLines = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") && !inCodeBlock {
                flushTable()
                flushText()
                inCodeBlock = true
                codeLang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if codeLang?.isEmpty == true { codeLang = nil }
            } else if line.hasPrefix("```") && inCodeBlock {
                let code = codeLines.joined(separator: "\n")
                segments.append(MarkdownSegment(content: code, kind: .code(language: codeLang)))
                codeLines = []
                inCodeBlock = false
                codeLang = nil
            } else if inCodeBlock {
                codeLines.append(line)
            } else if trimmed.hasPrefix("|") {
                // Accumulate table lines
                if tableLines.isEmpty {
                    flushText()
                }
                tableLines.append(trimmed)
            } else {
                if !tableLines.isEmpty {
                    flushTable()
                }
                currentText.append(line)
            }
        }

        // Flush remaining
        if inCodeBlock {
            let code = codeLines.joined(separator: "\n")
            segments.append(MarkdownSegment(content: code, kind: .code(language: codeLang)))
        } else {
            if !tableLines.isEmpty { flushTable() }
            flushText()
        }

        return segments
    }

    /// Parse markdown table lines into header + rows. Returns nil if not a valid table.
    private func parseTableLines(_ lines: [String]) -> (header: [String], rows: [[String]])? {
        guard lines.count >= 2 else { return nil }

        func splitRow(_ line: String) -> [String] {
            var s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("|") { s = String(s.dropFirst()) }
            if s.hasSuffix("|") { s = String(s.dropLast()) }
            return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }

        let header = splitRow(lines[0])

        // Check if line 1 is the separator (e.g. |---|---|)
        let separatorLine = lines[1].trimmingCharacters(in: .whitespaces)
        let isSeparator = separatorLine.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
            && separatorLine.contains("-")
        guard isSeparator else { return nil }

        var rows: [[String]] = []
        for i in 2..<lines.count {
            let row = splitRow(lines[i])
            rows.append(row)
        }

        return (header, rows)
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
