import Foundation
import SwiftUI

// MARK: - Topology Data Structures

enum NetworkTier: String, Sendable {
    case oracle
    case primeAuthority
    case authority
    case `operator`

    var color: Color {
        switch self {
        case .oracle: return .teal
        case .primeAuthority: return .purple
        case .authority: return .blue
        case .operator: return .orange
        }
    }

    var iconName: String {
        switch self {
        case .oracle: return "owl"  // SF Symbols — fallback handled in view
        case .primeAuthority: return "building.columns.fill"
        case .authority: return "building.columns"
        case .operator: return "server.rack"
        }
    }

    var nodeRadius: CGFloat {
        switch self {
        case .oracle: return 22
        case .primeAuthority: return 24
        case .authority: return 20
        case .operator: return 16
        }
    }

    var depthIndex: Int {
        switch self {
        case .oracle: return -1  // pinned, outside hierarchy
        case .primeAuthority: return 0
        case .authority: return 1
        case .operator: return 2
        }
    }
}

struct TopologyNode: Identifiable, Sendable {
    let id: String  // npub
    let displayName: String
    let tier: NetworkTier
    var children: [TopologyNode]
}

// MARK: - ViewModel

@MainActor
@Observable
final class TopologyViewModel {

    private(set) var roots: [TopologyNode] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    func buildTopology(
        authorities: [Authority],
        operators: [Operator]
    ) async {
        isLoading = true
        errorMessage = nil

        do {
            let entries = try await RegistryService.fetchRegistry()
            roots = buildTree(authorities: authorities, operators: operators, entries: entries)
        } catch {
            // Fallback: build from local data only
            roots = buildTreeFromLocalData(authorities: authorities, operators: operators)
        }

        isLoading = false
    }

    // MARK: - Tree Building

    private func buildTree(
        authorities: [Authority],
        operators: [Operator],
        entries: [RegistryService.RegistryEntry]
    ) -> [TopologyNode] {
        // Tolerant of duplicate npubs: synced entities can hold transient
        // duplicates between CloudKit import and the dedupe pass.
        let entryByNpub = Dictionary(entries.map { ($0.npub, $0) }, uniquingKeysWith: { first, _ in first })

        // Find Prime Authority from registry
        let primeEntries = entries.filter { $0.role == "prime_authority" }

        // While we have the registry in hand, persist each local Authority's
        // upstream certifier and backfill its tollbooth-authority MCP
        // endpoint. The Honor Chain's parent-of-Authority relationship is
        // discovered here, not stored separately.
        //
        // Skip Prime: Prime hosts the Oracle, not a tollbooth-authority
        // service. mcpEndpointURL on an Authority means "the authority MCP
        // service URL" — writing the Oracle URL there would cause callers
        // (like InvoiceListView) to issue check_balance / account_statement
        // against the Oracle, which has no such tools.
        for auth in authorities where !auth.isPrime {
            let entry = entryByNpub[auth.npub]
            if let upstream = entry?.upstream_authority_npub,
               auth.parentAuthorityNpub != upstream {
                auth.parentAuthorityNpub = upstream
            }
            if auth.mcpEndpointURL == nil,
               let url = entry?.services?.first?.url {
                auth.mcpEndpointURL = url
            }
        }

        // Build known authority npubs set (from local + registry)
        let localAuthNpubs = Set(authorities.map(\.npub))
        let registryAuthNpubs = Set(entries.filter { $0.role == "authority" || $0.role == "prime_authority" }.map(\.npub))
        let allAuthNpubs = localAuthNpubs.union(registryAuthNpubs)

        // Build operator nodes
        let operatorNodes: [String: TopologyNode] = Dictionary(
            operators.map { op in
                let node = TopologyNode(
                    id: op.npub,
                    displayName: op.displayName,
                    tier: .operator,
                    children: []
                )
                return (op.npub, node)
            },
            uniquingKeysWith: { first, _ in first }
        )

        // Helper: resolve an authority's parent npub from registry, falling back
        // to local SwiftData. Prime entries have no parent (returns nil).
        func parentOf(_ authNpub: String) -> String? {
            if let entry = entryByNpub[authNpub], entry.role != "prime_authority" {
                return entry.upstream_authority_npub
            }
            return authorities.first(where: { $0.npub == authNpub })?.parentAuthorityNpub
        }

        // Resolve display name for an authority — local store wins, then
        // registry, then truncated npub fallback.
        func displayNameFor(_ authNpub: String) -> String {
            if let local = authorities.first(where: { $0.npub == authNpub }) {
                return local.displayName
            }
            if let entry = entryByNpub[authNpub] {
                return entry.display_name ?? "Authority"
            }
            return "Authority \(authNpub.prefix(12))…"
        }

        // Build authority nodes recursively so a registered upstream chain
        // (Prime → NA → NE) actually renders as a chain instead of being
        // flattened under Prime. Includes operator children for each
        // authority. Cycle-guard via a visited set so a malformed registry
        // can't infinite-loop.
        let nonPrimeAuthNpubs = allAuthNpubs.subtracting(primeEntries.map(\.npub))

        func buildAuthorityNode(_ authNpub: String, visited: Set<String>) -> TopologyNode {
            let nextVisited = visited.union([authNpub])
            let operatorChildren = operators
                .filter { $0.authorityNpub == authNpub }
                .compactMap { operatorNodes[$0.npub] }
            let subAuthorityChildren = nonPrimeAuthNpubs
                .filter { !nextVisited.contains($0) && parentOf($0) == authNpub }
                .map { buildAuthorityNode($0, visited: nextVisited) }
            return TopologyNode(
                id: authNpub,
                displayName: displayNameFor(authNpub),
                tier: .authority,
                children: subAuthorityChildren + operatorChildren
            )
        }

        // Authorities whose upstream is unknown (no registry entry, no local
        // parent) hang directly off Prime so they remain visible while their
        // chain pointer is being resolved.
        let primeNpubs = Set(primeEntries.map(\.npub))
        let orphanedAuthNpubs = nonPrimeAuthNpubs.filter { authNpub in
            guard let parent = parentOf(authNpub) else { return true }
            return parent.isEmpty || !primeNpubs.contains(parent) && !nonPrimeAuthNpubs.contains(parent)
        }

        // Unattached operators (no authorityNpub or authority not known)
        let attachedNpubs = Set(operators.filter { op in
            guard let authNpub = op.authorityNpub else { return false }
            return allAuthNpubs.contains(authNpub)
        }.map(\.npub))
        let unattachedOps = operators
            .filter { !attachedNpubs.contains($0.npub) }
            .compactMap { operatorNodes[$0.npub] }

        // Build Prime node(s) — children are authorities whose upstream IS
        // Prime, recursively expanded, plus any orphans. Unattached operators
        // do NOT hang under Prime (would misleadingly suggest Prime adopted
        // them); they go in a sibling virtual "Unregistered Operators" node.
        var primeNodes: [TopologyNode] = primeEntries.map { entry in
            let directChildren = nonPrimeAuthNpubs
                .filter { parentOf($0) == entry.npub }
                .map { buildAuthorityNode($0, visited: [entry.npub]) }
            let orphanChildren = orphanedAuthNpubs
                .map { buildAuthorityNode($0, visited: [entry.npub]) }
            return TopologyNode(
                id: entry.npub,
                displayName: entry.display_name ?? "Prime Authority",
                tier: .primeAuthority,
                children: directChildren + orphanChildren
            )
        }

        if primeNodes.isEmpty {
            // No Prime in registry — create a virtual root containing every
            // top-level authority (any authority without a known parent in
            // this set), recursively built.
            let topLevelAuths = nonPrimeAuthNpubs.filter { parentOf($0).flatMap { nonPrimeAuthNpubs.contains($0) } != true }
            let topAuthorityNodes = topLevelAuths.map { buildAuthorityNode($0, visited: []) }
            if !topAuthorityNodes.isEmpty {
                primeNodes = [TopologyNode(
                    id: "prime",
                    displayName: "DPYC Network",
                    tier: .primeAuthority,
                    children: topAuthorityNodes
                )]
            }
        }

        if !unattachedOps.isEmpty {
            primeNodes.append(TopologyNode(
                id: "unregistered-operators",
                displayName: "Unregistered Operators",
                tier: .primeAuthority,
                children: unattachedOps
            ))
        }

        return primeNodes
    }

    private func buildTreeFromLocalData(
        authorities: [Authority],
        operators: [Operator]
    ) -> [TopologyNode] {
        let authNodes = authorities.map { auth in
            let children = operators
                .filter { $0.authorityNpub == auth.npub }
                .map { TopologyNode(id: $0.npub, displayName: $0.displayName, tier: .operator, children: []) }
            return TopologyNode(id: auth.npub, displayName: auth.displayName, tier: .authority, children: children)
        }

        let authNpubs = Set(authorities.map(\.npub))
        let unattachedOps = operators
            .filter { op in
                guard let authNpub = op.authorityNpub else { return true }
                return !authNpubs.contains(authNpub)
            }
            .map { TopologyNode(id: $0.npub, displayName: $0.displayName, tier: .operator, children: []) }

        var roots: [TopologyNode] = []
        if !authNodes.isEmpty {
            roots.append(TopologyNode(
                id: "prime",
                displayName: "DPYC Network",
                tier: .primeAuthority,
                children: authNodes
            ))
        }
        if !unattachedOps.isEmpty {
            roots.append(TopologyNode(
                id: "unregistered-operators",
                displayName: "Unregistered Operators",
                tier: .primeAuthority,
                children: unattachedOps
            ))
        }
        return roots
    }
}
