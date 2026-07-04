import Foundation
import SwiftData

/// Collapses duplicate synced entities after CloudKit merges devices' stores.
///
/// Before the CloudKit schema existed, every device built its own parallel
/// world: `ensurePrimeExists` minted a local Prime, registry auto-discovery
/// inserted local community members. The first real sync merged those worlds
/// — one record per device per npub. The models carry no unique constraints
/// (CloudKit forbids them), so uniqueness is restored here: richer optional
/// fields merge onto the surviving record, the copies are deleted, and the
/// deletions sync back out to the other devices.
@MainActor
enum EntityDeduplicator {

    /// Dedupe every synced entity type. Call on launch and on foreground
    /// activation — imports land while the app is away, so each return to
    /// the foreground is a chance to fold in what arrived.
    @discardableResult
    static func dedupeAll(in context: ModelContext) -> Int {
        var removed = 0
        removed += dedupe(Authority.self, in: context, npub: \.npub, addedAt: \.addedAt) { winner, loser in
            winner.nip05 = winner.nip05 ?? loser.nip05
            winner.mcpEndpointURL = winner.mcpEndpointURL ?? loser.mcpEndpointURL
            winner.parentAuthorityNpub = winner.parentAuthorityNpub ?? loser.parentAuthorityNpub
        }
        removed += dedupe(Operator.self, in: context, npub: \.npub, addedAt: \.addedAt) { winner, loser in
            winner.nip05 = winner.nip05 ?? loser.nip05
            winner.mcpEndpointURL = winner.mcpEndpointURL ?? loser.mcpEndpointURL
            winner.authorityNpub = winner.authorityNpub ?? loser.authorityNpub
            winner.deployedCampaignName = winner.deployedCampaignName ?? loser.deployedCampaignName
        }
        removed += dedupe(Patron.self, in: context, npub: \.npub, addedAt: \.addedAt) { winner, loser in
            winner.nip05 = winner.nip05 ?? loser.nip05
            winner.pictureURL = winner.pictureURL ?? loser.pictureURL
        }
        removed += dedupe(Contact.self, in: context, npub: \.npub, addedAt: \.addedAt) { winner, loser in
            winner.nip05 = winner.nip05 ?? loser.nip05
        }
        if removed > 0 {
            try? context.save()
            TrafficLogger.shared.log(.inbound, label: "Sync Dedupe",
                                     detail: "removed \(removed) duplicate record\(removed == 1 ? "" : "s")")
        }
        return removed
    }

    /// Group by npub; the oldest record wins (Prime's distantPast stamp keeps
    /// it stable), duplicates donate any fields the winner lacks and are
    /// deleted. Ties (two auto-created records with identical content) make
    /// the pick arbitrary but the merged result identical either way.
    private static func dedupe<T: PersistentModel>(
        _ type: T.Type,
        in context: ModelContext,
        npub: KeyPath<T, String>,
        addedAt: KeyPath<T, Date>,
        merge: (T, T) -> Void
    ) -> Int {
        let all = (try? context.fetch(FetchDescriptor<T>())) ?? []
        var removed = 0
        for (_, records) in Dictionary(grouping: all, by: { $0[keyPath: npub] }) where records.count > 1 {
            let sorted = records.sorted { $0[keyPath: addedAt] < $1[keyPath: addedAt] }
            let winner = sorted[0]
            for loser in sorted.dropFirst() {
                merge(winner, loser)
                context.delete(loser)
                removed += 1
            }
        }
        return removed
    }
}
