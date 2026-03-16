import SwiftUI

/// A sheet presenting known operator identities for the user to choose from.
///
/// Shown when ``ToolRoleClassifier`` returns `.ambiguous` or when multiple
/// operator nsecs are stored in Keychain.
struct IdentityPickerView: View {
    let identities: [(npub: String, displayName: String)]
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(identities, id: \.npub) { identity in
                Button {
                    onSelect(identity.npub)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(identity.displayName)
                            .font(.headline)
                        Text(identity.npub)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Choose Identity")
            #if os(macOS)
            .frame(minWidth: 360, minHeight: 200)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
