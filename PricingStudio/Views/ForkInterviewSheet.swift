import SwiftUI

/// Sheet for editing a message and replaying the interview from that point.
///
/// Shows the original message context and lets the operator edit the text
/// before forking. Can be used as a quick what-if or saved as a variant.
struct ForkInterviewSheet: View {
    let messageIndex: Int
    let initialText: String
    let isUserMessage: Bool
    var onFork: (String) -> Void
    var onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editText: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Context label
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isUserMessage ? "Edit & Replay" : "What-If from Here")
                            .font(.headline)
                        Text("The interview will replay from message \(messageIndex + 1) with your changes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

                Divider()

                // Edit area
                VStack(alignment: .leading, spacing: 4) {
                    Text(isUserMessage ? "Edit your message:" : "Replace with a new question or direction:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    TextEditor(text: $editText)
                        .font(.body)
                        .padding(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.3))
                        )
                        .padding(.horizontal)
                }

                Spacer()

                // Action buttons
                HStack(spacing: 12) {
                    Button("Cancel") {
                        dismiss()
                        onCancel()
                    }
                    .buttonStyle(.bordered)

                    Button {
                        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        dismiss()
                        onFork(text)
                    } label: {
                        Label("Fork & Replay", systemImage: "arrow.triangle.branch")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding()
            }
            .navigationTitle("Fork Interview")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                editText = initialText
            }
        }
    }
}
