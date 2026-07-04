import DPYCAuthKit
import SwiftUI

struct TrafficLogView: View {
    let logger: TrafficLogger
    var filterNpub: String?
    enum NpubFilter: String, CaseIterable { case include, exclude, only }
    @State private var npubFilter: NpubFilter = .include
    @State private var autoscroll = true
    @State private var isPaused = false
    @State private var frozenEntries: [TrafficLogEntry]?
    @State private var scrollToEnd = false
    enum NostrFilter: String, CaseIterable { case exclude, include, only }
    @State private var nostrFilter: NostrFilter = .exclude
    @State private var searchPattern = ""

    private var filteredEntries: [TrafficLogEntry] {
        var result = logger.entries

        // Npub filter
        if let npub = filterNpub, !npub.isEmpty {
            switch npubFilter {
            case .include:
                break // show everything
            case .exclude:
                result = result.filter { entry in
                    entry.associatedNpub != npub || entry.direction == .error
                }
            case .only:
                result = result.filter { entry in
                    entry.associatedNpub == nil
                        || entry.associatedNpub == npub
                        || entry.direction == .error
                }
            }
        }

        // Nostr event filter: exclude (default), include (show all), only (nostr only)
        switch nostrFilter {
        case .exclude:
            result = result.filter { !$0.isNostrEvent }
        case .include:
            break // show everything
        case .only:
            result = result.filter { $0.isNostrEvent || $0.direction == .error }
        }

        // Regex search — applies to ALL entries including errors
        if !searchPattern.isEmpty, let regex = try? NSRegularExpression(pattern: searchPattern, options: .caseInsensitive) {
            result = result.filter { entry in
                entryMatchesRegex(entry, regex)
            }
        }

        return result
    }

    /// What the list actually shows — frozen when paused.
    private var displayedEntries: [TrafficLogEntry] {
        frozenEntries ?? filteredEntries
    }

    private func entryMatchesRegex(_ entry: TrafficLogEntry, _ regex: NSRegularExpression) -> Bool {
        let fields = [
            entry.label,
            entry.detail,
            entry.url,
            entry.requestBody,
            entry.responseBody,
            entry.method
        ]
        for field in fields {
            guard let text = field, !text.isEmpty else { continue }
            if regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                return true
            }
        }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if displayedEntries.isEmpty {
                emptyState
            } else {
                logList
            }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack {
                Label("Traffic Log", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                pollHeartbeat
                if let npub = filterNpub, !npub.isEmpty {
                    Text(String(npub.prefix(12)) + "...")
                        .font(.caption)
                        .monospaced()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.blue)
                }
                if filterNpub != nil && !filterNpub!.isEmpty {
                    Picker("", selection: $npubFilter) {
                        Text("Include").tag(NpubFilter.include)
                        Text("Exclude").tag(NpubFilter.exclude)
                        Text("Only").tag(NpubFilter.only)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    .fixedSize()
                }

                Spacer()

                Text("\(displayedEntries.count)\(isPaused ? " paused" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("Nostr").font(.caption).foregroundStyle(.secondary)
                Picker("Nostr", selection: $nostrFilter) {
                    Text("Include").tag(NostrFilter.include)
                    Text("Exclude").tag(NostrFilter.exclude)
                    Text("Only").tag(NostrFilter.only)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .fixedSize()
                Button {
                    scrollToEnd = true
                } label: {
                    Label("End", systemImage: "arrow.down.to.line")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button {
                    isPaused.toggle()
                    if isPaused {
                        frozenEntries = filteredEntries
                        autoscroll = false
                    } else {
                        frozenEntries = nil
                        autoscroll = true
                    }
                } label: {
                    Label(isPaused ? "Resume" : "Pause",
                          systemImage: isPaused ? "play.fill" : "pause.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button {
                    logger.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(logger.entries.isEmpty)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Regex filter (label, detail, body)", text: $searchPattern)
                    .font(.caption)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                if !searchPattern.isEmpty {
                    Button {
                        searchPattern = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    if (try? NSRegularExpression(pattern: searchPattern)) == nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("Invalid regex pattern")
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var pollHeartbeat: some View {
        let polling = DMPollingService.shared
        let cycle = polling.pollCycle
        let running = polling.isPolling
        return HStack(spacing: 3) {
            Image(systemName: running ? "heart.fill" : "heart.slash")
                .font(.caption2)
                .foregroundStyle(running ? .red : .gray)
                .symbolEffect(.pulse, isActive: running && cycle > 0)
            if cycle > 0 {
                Text("#\(cycle)")
                    .font(.caption2)
                    .monospaced()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "text.page.slash")
                .font(.system(size: 32))
                .foregroundStyle(.quaternary)
            Text("No traffic yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Select an operator to see MCP traffic")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            List(displayedEntries) { entry in
                TrafficLogRow(entry: entry)
                    .id(entry.id)
                    .accessibilityIdentifier("trafficLogRow_\(entry.id.uuidString)")
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .onChange(of: logger.entries.count) {
                if autoscroll, !isPaused, let last = displayedEntries.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: scrollToEnd) {
                if scrollToEnd, let last = displayedEntries.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                    scrollToEnd = false
                }
            }
        }
    }
}

// MARK: - Log Row

private struct TrafficLogRow: View {
    let entry: TrafficLogEntry
    @State private var isExpanded = false

    private var hasStructuredDetail: Bool {
        entry.url != nil || entry.requestHeaders != nil || entry.requestBody != nil
            || entry.responseHeaders != nil || entry.responseBody != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Summary row — tap to expand/collapse
            HStack(spacing: 6) {
                directionBadge
                if let code = entry.statusCode {
                    statusBadge(code)
                }
                Text(entry.label)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                if hasStructuredDetail || !entry.detail.isEmpty {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospaced()
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }

            // Expanded detail — text is selectable/copyable
            if isExpanded {
                expandedContent
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            // URL line
            if let method = entry.method, let url = entry.url {
                fieldRow(header: "URL", value: "\(method) \(url)")
            }

            // Request headers
            if let headers = entry.requestHeaders, !headers.isEmpty {
                fieldRow(header: "Request Headers", value: formatHeaders(headers))
            }

            // Request body
            if let body = entry.requestBody, !body.isEmpty {
                fieldRow(header: "Request Body", value: body)
            }

            // Status code (if not already shown in badge)
            if let code = entry.statusCode, entry.url == nil {
                fieldRow(header: "Status", value: "HTTP \(code)")
            }

            // Response headers
            if let headers = entry.responseHeaders, !headers.isEmpty {
                fieldRow(header: "Response Headers", value: formatHeaders(headers))
            }

            // Response body
            if let body = entry.responseBody, !body.isEmpty {
                fieldRow(header: "Response Body", value: body)
            }

            // Fallback: plain detail (for MCP protocol-level entries without HTTP structure)
            if !hasStructuredDetail && !entry.detail.isEmpty {
                fieldRow(header: "Detail", value: entry.detail)
            }

            // Copy All button
            HStack {
                Spacer()
                Button {
                    UIPasteboard.general.string = copyableText
                } label: {
                    Label("Copy All", systemImage: "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private var copyableText: String {
        var parts: [String] = []
        parts.append("[\(entry.direction.rawValue)] \(entry.label)")
        if let method = entry.method, let url = entry.url {
            parts.append("URL: \(method) \(url)")
        }
        if let headers = entry.requestHeaders, !headers.isEmpty {
            parts.append("Request Headers:\n\(formatHeaders(headers))")
        }
        if let body = entry.requestBody, !body.isEmpty {
            parts.append("Request Body:\n\(body)")
        }
        if let code = entry.statusCode {
            parts.append("Status: HTTP \(code)")
        }
        if let headers = entry.responseHeaders, !headers.isEmpty {
            parts.append("Response Headers:\n\(formatHeaders(headers))")
        }
        if let body = entry.responseBody, !body.isEmpty {
            parts.append("Response Body:\n\(body)")
        }
        if !hasStructuredDetail && !entry.detail.isEmpty {
            parts.append("Detail:\n\(entry.detail)")
        }
        return parts.joined(separator: "\n\n")
    }

    private func fieldRow(header: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(header)
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2)
                .monospaced()
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }

    private func formatHeaders(_ headers: [String: String]) -> String {
        headers.sorted(by: { $0.key < $1.key })
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
    }

    private var directionBadge: some View {
        Text(entry.direction.rawValue)
            .font(.caption2)
            .fontWeight(.bold)
            .monospaced()
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(badgeColor)
    }

    private func statusBadge(_ code: Int) -> some View {
        Text("\(code)")
            .font(.caption2)
            .fontWeight(.semibold)
            .monospaced()
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(statusColor(code).opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(statusColor(code))
    }

    private var badgeColor: Color {
        switch entry.direction {
        case .outbound: return .blue
        case .inbound: return .green
        case .error: return .red
        }
    }

    private func statusColor(_ code: Int) -> Color {
        switch code {
        case 200...299: return .green
        case 300...399: return .orange
        default: return .red
        }
    }
}

#Preview {
    let logger = TrafficLogger()
    TrafficLogView(logger: logger)
        .onAppear {
            logger.logHTTP(
                label: "Registry Fetch",
                method: "GET",
                url: "https://raw.githubusercontent.com/lonniev/dpyc-community/main/members/read-only-lookup-cache.json",
                statusCode: 200,
                responseHeaders: ["content-type": "application/json", "x-cache": "HIT"],
                responseBody: "[{\"npub\":\"npub1y20...\",\"role\":\"operator\"}]"
            )
            logger.log(.outbound, label: "Oracle Connect", detail: "SSE → https://dpyc-oracle.fastmcp.app/mcp")
            logger.log(.outbound, label: "Oracle listTools", detail: "Discovering available tools")
            logger.log(.inbound, label: "Oracle listTools → 5 tools", detail: "lookup_member, how_to_join, about, get_tax_rate, network_advisory")
            logger.logHTTP(
                label: "OAuth Discovery",
                method: "GET",
                url: "https://personal-brain.fastmcp.app/.well-known/oauth-authorization-server",
                requestHeaders: ["Accept": "*/*"],
                statusCode: 200,
                responseHeaders: ["content-type": "application/json"],
                responseBody: "{\"authorization_endpoint\":\"https://auth.fastmcp.cloud/authorize\",\"token_endpoint\":\"https://auth.fastmcp.cloud/token\"}"
            )
            logger.logHTTP(
                label: "OAuth Token Exchange Failed",
                method: "POST",
                url: "https://auth.fastmcp.cloud/token",
                requestHeaders: ["Content-Type": "application/x-www-form-urlencoded"],
                requestBody: "grant_type=authorization_code&client_id=abc123",
                statusCode: 401,
                responseBody: "{\"error\":\"invalid_grant\",\"error_description\":\"Authorization code expired\"}",
                error: "HTTP 401 — invalid_grant"
            )
            logger.log(.error, label: "Operator MCP Connect Failed", detail: "Error Domain=NSURLErrorDomain Code=-1004 \"Could not connect to the server.\"")
        }
}
