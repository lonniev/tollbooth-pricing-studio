import SwiftUI

/// Prompt selector for the DPYC Oracle — tapping a prompt sends it
/// to the existing AI Assistant view for query execution and rendering.
/// No answers are fetched or shown here.
struct OraclePromptPanel: View {
    var onPromptSelected: (String) -> Void
    @State private var customPrompt = ""

    private let starterPrompts = [
        "What is the DPYC?",
        "Why all the Tollbooth analogies?",
        "Can I bring my own MCP Operator?",
        "What does an Authority do?",
        "Who is making money here and how?",
        "Where do I get a Nostr npub?",
        "Can I try making a paid toll call?",
        "If I have an Operator's npub, can I look up its MCP URL?",
        "How do I start a Pricing Campaign?",
        "How do I join?",
        "How do I add a new Authority?",
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("🦉")
                    .font(.title3)
                Text("Ask the Oracle")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            Divider()

            // Prompt list
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(starterPrompts, id: \.self) { prompt in
                        Button {
                            onPromptSelected(prompt)
                        } label: {
                            HStack {
                                Text(prompt)
                                    .font(.subheadline)
                                    .multilineTextAlignment(.leading)
                                Spacer()
                                Image(systemName: "arrow.right.circle")
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.quaternary.opacity(0.3))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
            }

            Divider()

            // Custom prompt input
            HStack(spacing: 8) {
                TextField("Or ask your own question…", text: $customPrompt)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onSubmit { sendCustom() }

                Button {
                    sendCustom()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(customPrompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(.background)
    }

    private func sendCustom() {
        let text = customPrompt.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        customPrompt = ""
        onPromptSelected(text)
    }
}
