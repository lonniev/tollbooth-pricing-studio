import SwiftUI
import SwiftData

/// Sheet for composing a new DM to a recipient npub.
struct ComposeMessageSheet: View {
    @Bindable var chatVM: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Authority.addedAt) private var authorities: [Authority]
    @Query(sort: \Operator.addedAt) private var operators: [Operator]
    @Query(sort: \Patron.addedAt) private var patrons: [Patron]
    @Query(sort: \Contact.addedAt) private var contacts: [Contact]

    @State private var recipientNpub = ""
    @State private var messageText = ""
    @State private var validationError: String?
    @State private var isSending = false
    @State private var showingSaveContact = false
    @State private var contactDisplayName = ""

    private var suggestions: [ContactSuggestion] {
        let ownNpub = chatVM.currentIdentity?.npub
        var seen = Set<String>()
        var result: [ContactSuggestion] = []

        for auth in authorities {
            if auth.npub != ownNpub, seen.insert(auth.npub).inserted {
                result.append(ContactSuggestion(npub: auth.npub, displayName: auth.displayName, kind: "Authority"))
            }
        }
        for op in operators {
            if op.npub != ownNpub, seen.insert(op.npub).inserted {
                result.append(ContactSuggestion(npub: op.npub, displayName: op.displayName, kind: "Operator"))
            }
        }
        for patron in patrons {
            if patron.npub != ownNpub, seen.insert(patron.npub).inserted {
                result.append(ContactSuggestion(npub: patron.npub, displayName: patron.displayName, kind: "Patron"))
            }
        }
        for contact in contacts {
            if contact.npub != ownNpub, seen.insert(contact.npub).inserted {
                result.append(ContactSuggestion(npub: contact.npub, displayName: contact.displayName, kind: "Contact"))
            }
        }

        return result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var filteredSuggestions: [ContactSuggestion] {
        let query = recipientNpub.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return suggestions }
        return suggestions.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
            || $0.npub.lowercased().hasPrefix(query)
        }
    }

    private var isKnownNpub: Bool {
        let npub = recipientNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        return suggestions.contains { $0.npub == npub }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Recipient") {
                    TextField("npub1... or search by name", text: $recipientNpub)
                        .monospaced()
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("recipientNpubField")

                    if let error = validationError {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                if !filteredSuggestions.isEmpty {
                    Section(recipientNpub.trimmingCharacters(in: .whitespaces).isEmpty ? "Known Entities" : "Suggestions") {
                        ForEach(filteredSuggestions) { suggestion in
                            Button {
                                recipientNpub = suggestion.npub
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(suggestion.displayName)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                        Text(truncatedNpub(suggestion.npub))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .monospaced()
                                    }
                                    Spacer()
                                    Text(suggestion.kind)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }

                Section("Message") {
                    TextEditor(text: $messageText)
                        .font(.custom(chatVM.messageFontName, size: chatVM.messageFontSize))
                        .frame(minHeight: 100)
                        .accessibilityIdentifier("composeMessageBody")

                    HStack {
                        Spacer()
                        Button {
                            send()
                        } label: {
                            if isSending {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Send", systemImage: "paperplane.fill")
                                    .foregroundStyle(.white)
                            }
                        }
                        .accessibilityIdentifier("sendMessageButton")
                        .buttonStyle(.borderedProminent)
                        .disabled(isSending || recipientNpub.isEmpty || messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .navigationTitle("New Message")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Save as Contact?", isPresented: $showingSaveContact) {
                TextField("Display name", text: $contactDisplayName)
                Button("Save") {
                    let npub = recipientNpub.trimmingCharacters(in: .whitespacesAndNewlines)
                    let name = contactDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    let contact = Contact(npub: npub, displayName: name)
                    modelContext.insert(contact)
                    try? modelContext.save()
                    dismiss()
                }
                Button("Skip", role: .cancel) {
                    dismiss()
                }
            } message: {
                Text("This npub isn't saved yet. Would you like to save it as a reusable contact?")
            }
        }
    }

    private func send() {
        guard !isSending else { return }

        let npub = recipientNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        guard npub.hasPrefix("npub1") else {
            validationError = "Must start with npub1"
            return
        }
        guard let pubHex = try? NostrKeyService.publicKeyHexFromNpub(npub) else {
            validationError = "Invalid npub format"
            return
        }

        isSending = true
        let message = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await chatVM.sendMessage(to: pubHex, content: message)
            isSending = false
            chatVM.selectedConversationId = pubHex
            if !isKnownNpub {
                showingSaveContact = true
            } else {
                dismiss()
            }
        }
    }

    private func truncatedNpub(_ npub: String) -> String {
        guard npub.count > 16 else { return npub }
        let prefix = npub.prefix(12)
        let suffix = npub.suffix(4)
        return "\(prefix)...\(suffix)"
    }
}

private struct ContactSuggestion: Identifiable {
    let npub: String
    let displayName: String
    let kind: String

    var id: String { npub }
}
