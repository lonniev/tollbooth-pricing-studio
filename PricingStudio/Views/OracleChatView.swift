import SwiftUI

/// AI chat assistant backed by the DPYC Oracle for RAG-powered answers.
/// Pre-loaded with starter prompts for common newcomer questions.
struct OracleChatView: View {
    @State private var messages: [(id: UUID, role: String, text: String)] = []
    @State private var input = ""
    @State private var isThinking = false

    private let starterPrompts = [
        "What is the DPYC?",
        "Why all the Tollbooth analogies?",
        "Can I bring my own MCP Operator?",
        "What does an Authority do?",
        "Who is making money here and how?",
        "Where do I get a Nostr npub?",
        "Can I try making a paid toll call?",
        "Where is the MCP for npub…?",
        "How do I join?",
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("🦉")
                    .font(.title3)
                Text("DPYC Oracle")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            Divider()

            if messages.isEmpty {
                welcomeView
            } else {
                messageList
            }

            Divider()
            inputBar
        }
        .background(.background)
    }

    // MARK: - Welcome

    private var welcomeView: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("🦉")
                    .font(.system(size: 64))

                Text("Ask the Oracle")
                    .font(.title2.bold())

                Text("The DPYC Oracle answers questions about the Honor Chain, Tollbooth economics, membership, and how to get started.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)

                VStack(spacing: 8) {
                    ForEach(starterPrompts, id: \.self) { prompt in
                        Button {
                            sendMessage(prompt)
                        } label: {
                            HStack {
                                Text(prompt)
                                    .font(.subheadline)
                                    .multilineTextAlignment(.leading)
                                Spacer()
                                Image(systemName: "arrow.right.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.quaternary.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 500)
            }
            .padding()
        }
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages, id: \.id) { msg in
                        messageBubble(role: msg.role, text: msg.text)
                            .id(msg.id)
                    }

                    if isThinking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Consulting the Oracle…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .id("thinking")
                    }
                }
                .padding()
            }
            .onChange(of: messages.count) {
                if let last = messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func messageBubble(role: String, text: String) -> some View {
        VStack(alignment: role == "user" ? .trailing : .leading, spacing: 4) {
            HStack {
                if role == "user" { Spacer(minLength: 60) }

                Text(text)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        role == "user"
                            ? Color.accentColor.opacity(0.15)
                            : Color(.secondarySystemBackground)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                if role != "user" { Spacer(minLength: 60) }
            }
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask the Oracle…", text: $input)
                .textFieldStyle(.plain)
                .padding(10)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .onSubmit { sendCurrentInput() }

            Button {
                sendCurrentInput()
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || isThinking)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func sendCurrentInput() {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        input = ""
        sendMessage(text)
    }

    private func sendMessage(_ text: String) {
        messages.append((id: UUID(), role: "user", text: text))
        isThinking = true

        Task {
            let response = await queryOracle(text)
            messages.append((id: UUID(), role: "assistant", text: response))
            isThinking = false
        }
    }

    /// Query the Oracle MCP tools based on the user's question.
    /// Routes to the appropriate tool and formats the response.
    private func queryOracle(_ question: String) async -> String {
        let q = question.lowercased()
        let mcpService = MCPService()

        // Route to the most relevant Oracle tool
        do {
            if q.contains("join") || q.contains("start") || q.contains("try") || q.contains("how do i") {
                return try await callOracleTool(mcpService, tool: "how_to_join")
            } else if q.contains("what is") || q.contains("dpyc") || q.contains("about") || q.contains("tollbooth") || q.contains("analog") {
                return try await callOracleTool(mcpService, tool: "about")
            } else if q.contains("money") || q.contains("economic") || q.contains("revenue") || q.contains("pricing") || q.contains("cost") {
                return try await callOracleTool(mcpService, tool: "economic_model")
            } else if q.contains("authority") || q.contains("rule") || q.contains("governance") {
                return try await callOracleTool(mcpService, tool: "get_rulebook")
            } else if q.contains("npub") || q.contains("nostr") || q.contains("key") {
                if q.contains("where is") || q.contains("mcp for") {
                    // Try to extract npub from question
                    if let npubRange = question.range(of: "npub1\\w+", options: .regularExpression) {
                        let npub = String(question[npubRange])
                        return try await callOracleTool(mcpService, tool: "lookup_member", args: ["npub": npub])
                    }
                }
                return try await callOracleTool(mcpService, tool: "how_to_join")
            } else if q.contains("advisory") || q.contains("update") || q.contains("version") {
                return try await callOracleTool(mcpService, tool: "network_advisory")
            } else {
                // Default: about
                return try await callOracleTool(mcpService, tool: "about")
            }
        } catch {
            return "The Oracle is currently unreachable. Error: \(error.localizedDescription)"
        }
    }

    private func callOracleTool(_ mcpService: MCPService, tool: String, args: [String: String] = [:]) async throws -> String {
        // Use the Oracle's FastMCP Cloud endpoint
        guard let oracleURL = URL(string: "https://dpyc-oracle.fastmcp.app/mcp") else {
            return "Oracle endpoint not configured."
        }

        let response = try await mcpService.callToolGeneric(
            endpointURL: oracleURL,
            bearerToken: "",
            toolName: tool
        )

        // Try to extract readable content from JSON response
        if let data = response.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let result = json["result"] as? String {
            return result
        }

        return response
    }
}
