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
        let hasBlocks = segments.contains(where: { $0.isCodeBlock || $0.isTable || $0.isStatus }) || Self.containsBlockMarkdown(text)
        if hasBlocks {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment.kind {
                    case .code(let language):
                        codeBlockView(segment.content, language: language)
                    case .table(let header, let rows):
                        tableView(header: header, rows: rows)
                    case .status(let labels):
                        statusView(labels)
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

    /// A real grid: every column shares one width, cells wrap instead of
    /// running off the edge, and the last column takes the slack.
    @ViewBuilder
    private func tableView(header: [String], rows: [[String]]) -> some View {
        let colCount = header.count
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                ForEach(0..<colCount, id: \.self) { col in
                    Text(Self.markdownAttributed(header[col]))
                        .font(.subheadline.bold())
                        .frame(maxWidth: col == colCount - 1 ? .infinity : nil, alignment: .leading)
                }
            }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                GridRow {
                    ForEach(0..<colCount, id: \.self) { col in
                        Text(Self.markdownAttributed(col < row.count ? row[col] : ""))
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: col == colCount - 1 ? .infinity : nil, alignment: .leading)
                    }
                }
                if rowIdx < rows.count - 1 {
                    Divider().opacity(0.5)
                }
            }
        }
        .padding(10)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Tool Status

    /// Status lines the tool loop streams into a reply ("*Consulting Operator…*",
    /// "_Summary updated._"). Adjacent ones collapse into one row of small chips.
    static func statusLabel(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t == "_Summary updated._" { return "Summary" }
        for (open, close) in [("*Consulting ", "…*"), ("*Consulting ", "...*")] {
            if t.hasPrefix(open), t.hasSuffix(close), t.count > open.count + close.count {
                return String(t.dropFirst(open.count).dropLast(close.count))
            }
        }
        return nil
    }

    private static func statusIcon(_ label: String) -> String {
        switch label {
        case "Summary": return "note.text"
        case "Oracle": return "sparkle.magnifyingglass"
        default: return "server.rack"
        }
    }

    @ViewBuilder
    private func statusView(_ labels: [String]) -> some View {
        var order: [String] = []
        var counts: [String: Int] = [:]
        let _ = labels.forEach { l in
            if counts[l] == nil { order.append(l) }
            counts[l, default: 0] += 1
        }
        HStack(spacing: 6) {
            ForEach(order, id: \.self) { label in
                let n = counts[label] ?? 1
                Label(n > 1 ? "\(label) ×\(n)" : label, systemImage: Self.statusIcon(label))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.5), in: Capsule())
            }
        }
    }

    // MARK: - Segment Parsing

    enum SegmentKind {
        case text
        case code(language: String?)
        case table(header: [String], rows: [[String]])
        case status([String])
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
        var isStatus: Bool {
            if case .status = kind { return true }
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
        var statusLabels: [String] = []

        func flushStatus() {
            if !statusLabels.isEmpty {
                segments.append(MarkdownSegment(content: "", kind: .status(statusLabels)))
                statusLabels = []
            }
        }

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
                flushStatus()
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
            } else if let label = statusLabel(trimmed) {
                if !tableLines.isEmpty { flushTable() }
                flushText()
                statusLabels.append(label)
            } else if trimmed.isEmpty && !statusLabels.isEmpty && currentText.isEmpty && tableLines.isEmpty {
                continue
            } else if trimmed.hasPrefix("|") {
                flushStatus()
                if tableLines.isEmpty {
                    flushText()
                }
                tableLines.append(trimmed)
            } else {
                flushStatus()
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
            flushStatus()
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
