import SwiftUI

/// Shared block-level markdown renderer.
///
/// Supports code blocks, tables, headings, lists, dividers,
/// and inline markdown. Used by both AssistantPanelView and
/// PricingConsultantView for consistent markdown rendering.
struct MarkdownContentView: View {
    let text: String

    var body: some View {
        let segments = Self.parseMarkdownSegments(text)
        let hasBlocks = segments.contains(where: { $0.isCodeBlock || $0.isTable }) || Self.containsBlockMarkdown(text)
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
            .textSelection(.enabled)
        } else {
            Text(Self.markdownAttributed(text))
                .textSelection(.enabled)
        }
    }

    // MARK: - Block Detection

    static func containsBlockMarkdown(_ text: String) -> Bool {
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

    // MARK: - Block Text Rendering

    @ViewBuilder
    private func renderBlockText(_ text: String) -> some View {
        let lines = text.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                    Divider()
                        .padding(.vertical, 4)
                } else if let heading = Self.parseHeading(trimmed) {
                    Text(Self.markdownAttributed(heading.text))
                        .font(heading.font)
                        .padding(.top, heading.level == 1 ? 12 : 8)
                } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    HStack(alignment: .top, spacing: 6) {
                        Text("\u{2022}")
                            .font(.body)
                        Text(Self.markdownAttributed(String(trimmed.dropFirst(2))))
                    }
                } else if let range = trimmed.range(of: #"^(\d+)\.\s"#, options: .regularExpression) {
                    let prefix = String(trimmed[range])
                    let rest = String(trimmed[range.upperBound...])
                    HStack(alignment: .top, spacing: 4) {
                        Text(prefix)
                            .foregroundStyle(.secondary)
                        Text(Self.markdownAttributed(rest))
                    }
                } else if trimmed.isEmpty {
                    // Paragraph break — add vertical space
                    Spacer().frame(height: 8)
                } else {
                    Text(Self.markdownAttributed(trimmed))
                }
            }
        }
    }

    // MARK: - Heading Parsing

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

    private static func parseHeading(_ line: String) -> HeadingInfo? {
        if line.hasPrefix("### ") {
            return HeadingInfo(level: 3, text: String(line.dropFirst(4)))
        } else if line.hasPrefix("## ") {
            return HeadingInfo(level: 2, text: String(line.dropFirst(3)))
        } else if line.hasPrefix("# ") {
            return HeadingInfo(level: 1, text: String(line.dropFirst(2)))
        }
        return nil
    }

    // MARK: - Inline Markdown

    static func markdownAttributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    // MARK: - Code Block

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

    // MARK: - Table

    @ViewBuilder
    private func tableView(header: [String], rows: [[String]]) -> some View {
        let colCount = header.count
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(Self.markdownAttributed(cell))
                            .font(.system(.caption, design: .monospaced).bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(minWidth: 60, alignment: .leading)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                    HStack(spacing: 0) {
                        ForEach(0..<colCount, id: \.self) { colIdx in
                            Text(Self.markdownAttributed(colIdx < row.count ? row[colIdx] : ""))
                                .font(.system(.caption, design: .monospaced))
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

    // MARK: - Segment Parsing

    enum SegmentKind {
        case text
        case code(language: String?)
        case table(header: [String], rows: [[String]])
    }

    struct MarkdownSegment {
        let content: String
        let kind: SegmentKind

        var isCodeBlock: Bool {
            if case .code = kind { return true }
            return false
        }
        var isTable: Bool {
            if case .table = kind { return true }
            return false
        }
    }

    static func parseMarkdownSegments(_ text: String) -> [MarkdownSegment] {
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

        if inCodeBlock {
            let code = codeLines.joined(separator: "\n")
            segments.append(MarkdownSegment(content: code, kind: .code(language: codeLang)))
        } else {
            if !tableLines.isEmpty { flushTable() }
            flushText()
        }

        return segments
    }

    static func parseTableLines(_ lines: [String]) -> (header: [String], rows: [[String]])? {
        guard lines.count >= 2 else { return nil }

        func splitRow(_ line: String) -> [String] {
            var s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("|") { s = String(s.dropFirst()) }
            if s.hasSuffix("|") { s = String(s.dropLast()) }
            return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }

        let header = splitRow(lines[0])

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
}
