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
        let entryByNpub = Dictionary(uniqueKeysWithValues: entries.map { ($0.npub, $0) })

        // Find Prime Authority from registry
        let primeEntries = entries.filter { $0.role == "prime_authority" }

        // While we have the registry in hand, persist each Authority's
        // upstream certifier into its SwiftData record. The Honor Chain's
        // parent-of-Authority relationship is discovered here, not stored
        // separately. Skip Prime — it has no upstream.
        for auth in authorities where !auth.isPrime {
            if let upstream = entryByNpub[auth.npub]?.upstream_authority_npub,
               auth.parentAuthorityNpub != upstream {
                auth.parentAuthorityNpub = upstream
            }
        }

        // Build known authority npubs set (from local + registry)
        let localAuthNpubs = Set(authorities.map(\.npub))
        let registryAuthNpubs = Set(entries.filter { $0.role == "authority" || $0.role == "prime_authority" }.map(\.npub))
        let allAuthNpubs = localAuthNpubs.union(registryAuthNpubs)

        // Build operator nodes
        let operatorNodes: [String: TopologyNode] = Dictionary(uniqueKeysWithValues:
            operators.map { op in
                let node = TopologyNode(
                    id: op.npub,
                    displayName: op.displayName,
                    tier: .operator,
                    children: []
                )
                return (op.npub, node)
            }
        )

        // Build authority nodes, attaching operator children
        var authorityNodes: [String: TopologyNode] = [:]
        for authNpub in allAuthNpubs {
            if registryAuthNpubs.contains(authNpub) && primeEntries.contains(where: { $0.npub == authNpub }) {
                continue  // Prime Authority handled separately
            }
            let displayName: String
            if let local = authorities.first(where: { $0.npub == authNpub }) {
                displayName = local.displayName
            } else if let entry = entryByNpub[authNpub] {
                displayName = entry.display_name ?? "Authority"
            } else {
                displayName = "Authority \(authNpub.prefix(12))…"
            }

            let children = operators
                .filter { $0.authorityNpub == authNpub }
                .compactMap { operatorNodes[$0.npub] }

            authorityNodes[authNpub] = TopologyNode(
                id: authNpub,
                displayName: displayName,
                tier: .authority,
                children: children
            )
        }

        // Unattached operators (no authorityNpub or authority not known)
        let attachedNpubs = Set(operators.filter { op in
            guard let authNpub = op.authorityNpub else { return false }
            return authorityNodes[authNpub] != nil
        }.map(\.npub))
        let unattachedOps = operators
            .filter { !attachedNpubs.contains($0.npub) }
            .compactMap { operatorNodes[$0.npub] }

        // Build Prime node(s)
        var primeNodes: [TopologyNode] = primeEntries.map { entry in
            let children = Array(authorityNodes.values) + unattachedOps
            return TopologyNode(
                id: entry.npub,
                displayName: entry.display_name ?? "Prime Authority",
                tier: .primeAuthority,
                children: children
            )
        }

        if primeNodes.isEmpty {
            // No Prime in registry — create a virtual root
            let allChildren = Array(authorityNodes.values) + unattachedOps
            if !allChildren.isEmpty {
                primeNodes = [TopologyNode(
                    id: "prime",
                    displayName: "DPYC Network",
                    tier: .primeAuthority,
                    children: allChildren
                )]
            }
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

        let unattachedOps = operators
            .filter { $0.authorityNpub == nil || !authorities.contains(where: { $0.npub == $0.npub }) }
            .map { TopologyNode(id: $0.npub, displayName: $0.displayName, tier: .operator, children: []) }

        let allChildren = authNodes + unattachedOps
        guard !allChildren.isEmpty else { return [] }

        return [TopologyNode(
            id: "prime",
            displayName: "DPYC Network",
            tier: .primeAuthority,
            children: allChildren
        )]
    }
}
