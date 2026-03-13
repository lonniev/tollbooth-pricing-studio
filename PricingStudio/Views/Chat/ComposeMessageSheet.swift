import SwiftUI

/// Sheet for composing a new DM to a recipient npub.
struct ComposeMessageSheet: View {
    @Bindable var chatVM: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var recipientNpub = ""
    @State private var messageText = ""
    @State private var validationError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Recipient") {
                    TextField("npub1...", text: $recipientNpub)
                        .monospaced()
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    if let error = validationError {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                Section("Message") {
                    TextEditor(text: $messageText)
                        .font(.custom(chatVM.messageFontName, size: chatVM.messageFontSize))
                        .frame(minHeight: 100)
                }
            }
            .navigationTitle("New Message")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        send()
                    }
                    .disabled(recipientNpub.isEmpty || messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func send() {
        let npub = recipientNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        guard npub.hasPrefix("npub1") else {
            validationError = "Must start with npub1"
            return
        }
        guard let pubHex = try? NostrKeyService.publicKeyHexFromNpub(npub) else {
            validationError = "Invalid npub format"
            return
        }

        let message = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await chatVM.sendMessage(to: pubHex, content: message)
            dismiss()
        }
    }
}
