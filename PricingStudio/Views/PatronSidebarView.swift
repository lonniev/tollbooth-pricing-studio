import SwiftUI
import PricingStudioCore
import SwiftData

struct PatronSidebarView: View {
    @Query(sort: \Patron.addedAt) private var patrons: [Patron]
    @Environment(\.modelContext) private var modelContext
    @Bindable var viewModel: PatronCollectionViewModel

    var body: some View {
        ForEach(patrons) { patron in
            PatronRow(patron: patron, isSelected: viewModel.selectedPatron?.id == patron.id)
                .contentShape(Rectangle())
                .onTapGesture { viewModel.selectedPatron = patron }
                .tag(patron)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        viewModel.requestDelete(patron)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button {
                        viewModel.requestEdit(patron)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Divider()
                    Button(role: .destructive) {
                        viewModel.requestDelete(patron)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
        }
    }
}

private struct PatronRow: View {
    let patron: Patron
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    PatronAvatar(pictureURL: patron.pictureURL, size: 22)
                    Text(patron.displayName)
                        .font(.headline)
                }
                Text(truncatedNpub(patron.npub))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }
            Spacer()
            if KeychainService.loadNsec(forNpub: patron.npub) != nil {
                Image(systemName: "checkmark.shield.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .help("Signing key (nsec) stored in your Keychain")
            }
            if (DMPollingService.shared.unreadCounts[patron.npub] ?? 0) > 0 {
                Image(systemName: "envelope.badge.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("You have new Nostr DMs")
            }
            if NostrNotificationPreferences.isMuted(npub: patron.npub) {
                Image(systemName: "bell.slash.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Notifications muted for this patron")
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.15) : nil)
    }

    private func truncatedNpub(_ npub: String) -> String {
        guard npub.count > 16 else { return npub }
        let prefix = npub.prefix(12)
        let suffix = npub.suffix(4)
        return "\(prefix)...\(suffix)"
    }
}
