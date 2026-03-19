import SwiftUI

struct TrafficLogView: View {
    let logger: TrafficLogger
    var filterNpub: String?

    /// Show entries where:
    /// - the entry is tagged for the selected npub (sender or receiver)
    /// - the entry has no npub tag (general app-level traffic like relay connects)
    /// - the entry is an error (always visible)
    /// This hides only traffic explicitly tagged for a *different* npub.
    private var filteredEntries: [TrafficLogEntry] {
        guard let npub = filterNpub, !npub.isEmpty else {
            return logger.entries
        }
        return logger.entries.filter { entry in
            entry.associatedNpub == nil           // general app traffic
                || entry.associatedNpub == npub   // tagged for this npub
                || entry.direction == .error       // always show errors
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if filteredEntries.isEmpty {
                emptyState
            } else {
                logList
            }
        }
    }

    private var header: some View {
        HStack {
            Label("Traffic Log", systemImage: "antenna.radiowaves.left.and.right")
                .font(.headline)
            if let npub = filterNpub, !npub.isEmpty {
                Text(String(npub.prefix(12)) + "...")
                    .font(.caption)
                    .monospaced()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.blue)
            }
            Spacer()
            Text("\(filteredEntries.count) entries")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        .padding(.horizontal)
        .padding(.vertical, 8)
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
            List(filteredEntries) { entry in
                TrafficLogRow(entry: entry)
                    .id(entry.id)
                    .accessibilityIdentifier("trafficLogRow_\(entry.id.uuidString)")
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .onChange(of: logger.entries.count) {
                if let last = filteredEntries.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
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
