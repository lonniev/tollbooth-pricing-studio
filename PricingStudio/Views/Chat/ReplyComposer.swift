import SwiftUI

/// Large-frame text editor for composing replies.
struct ReplyComposer: View {
    let fontName: String
    let fontSize: CGFloat
    let onSend: (String) -> Void

    @State private var text = ""

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextEditor(text: $text)
                .font(.custom(fontName, size: fontSize))
                .frame(minHeight: 40, maxHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            Button {
                let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !message.isEmpty else { return }
                onSend(message)
                text = ""
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.title3)
            }
            .accessibilityIdentifier("replySendButton")
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}
