import SwiftUI

/// Starter questions shown in the empty Oracle chat. Tapping one sends it.
/// The questions carry no facts: the Oracle answers each from its live tools.
struct OracleStarterPrompts: View {
    var onPromptSelected: (String) -> Void

    static let prompts = [
        "What is the DPYC?",
        "Why all the Tollbooth analogies?",
        "Can I bring my own MCP Operator?",
        "What does an Authority do?",
        "Who is making money here and how?",
        "Where do I get a Nostr npub?",
        "Which Lightning wallet should I use?",
        "Can I try making a paid toll call?",
        "If I have an Operator's npub, can I look up its MCP URL?",
        "How do I start a Pricing Campaign?",
        "How do I join?",
        "How do I add a new Authority?",
    ]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Self.prompts, id: \.self) { prompt in
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
    }
}
