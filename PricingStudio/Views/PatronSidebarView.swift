import SwiftUI
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
                    Image(systemName: "person.badge.key")
                        .foregroundStyle(.teal)
                        .font(.caption)
                    Text(patron.displayName)
                        .font(.headline)
                    if (DMPollingService.shared.unreadCounts[patron.npub] ?? 0) > 0 {
                        Image(systemName: "envelope.badge.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
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
