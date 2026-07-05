import SwiftUI
import SwiftData

struct NetworkTopologyView: View {
    @Query(sort: \Authority.addedAt) private var authorities: [Authority]
    @Query(sort: \Operator.addedAt) private var operators: [Operator]
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var topologyVM = TopologyViewModel()
    @State private var selectedNpub: String?
    @State private var showingOracleChat = false
    /// Npubs of nodes whose subtree is currently collapsed in the canvas.
    /// Empty = fully expanded.
    @State private var collapsedNpubs: Set<String> = []

    private var isCompact: Bool { sizeClass == .compact }

    var onNodeSelected: ((String, NetworkTier) -> Void)?
    var onOraclePrompt: ((String) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            graphContent
        }
        // Compact has no room for the floating Oracle panel — present it as a
        // sheet (opened from the header owl).
        .sheet(isPresented: Binding(
            get: { isCompact && showingOracleChat },
            set: { showingOracleChat = $0 }
        )) {
            NavigationStack {
                OraclePromptPanel { prompt in
                    showingOracleChat = false
                    onOraclePrompt?(prompt)
                }
                .navigationTitle("Ask the Oracle")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { showingOracleChat = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .task {
            await topologyVM.buildTopology(authorities: authorities, operators: operators)
        }
        .onChange(of: authorities.count) { _, _ in
            Task { await topologyVM.buildTopology(authorities: authorities, operators: operators) }
        }
        .onChange(of: operators.count) { _, _ in
            Task { await topologyVM.buildTopology(authorities: authorities, operators: operators) }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Network Topology")
                    .font(.title3.bold())
                Text("DPYC Infrastructure Providers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // The legend explains the spatial graph; on compact (a list) it's
            // noise, so the header carries the Oracle entry point instead.
            if isCompact {
                Button {
                    showingOracleChat = true
                } label: {
                    Text("🦉").font(.title2)
                }
                .accessibilityLabel("Ask the Oracle")
            } else {
                legendView
            }
        }
        .padding()
    }

    private var legendView: some View {
        HStack(spacing: 16) {
            legendItem(tier: .oracle, label: "Oracle")
            legendItem(tier: .primeAuthority, label: "Prime")
            legendItem(tier: .authority, label: "Authority")
            legendItem(tier: .operator, label: "Operator")
        }
        .font(.caption2)
    }

    private func legendItem(tier: NetworkTier, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(tier.color)
                .frame(width: 8, height: 8)
            Text(label)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var graphContent: some View {
        if topologyVM.isLoading {
            loadingContent
        } else if topologyVM.roots.isEmpty {
            emptyContent
        } else if isCompact {
            // A phone can't usefully pan the spatial canvas; the same tree
            // reads far better as a native collapsible outline.
            TopologyListView(roots: topologyVM.roots) { npub, tier in
                selectedNpub = npub
                onNodeSelected?(npub, tier)
            }
        } else {
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    topologyCanvas(size: geometry.size)
                }
            }
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: 8) {
                    oracleNode

                    if showingOracleChat {
                        OraclePromptPanel { prompt in
                            onOraclePrompt?(prompt)
                        }
                        .frame(width: 340, height: 420)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(radius: 12)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(.top, 8)
                .padding(.trailing, 16)
            }
        }
    }

    private var loadingContent: some View {
        VStack(spacing: 24) {
            Image("MiloGreeting")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 400)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 8)

            Text("Pricing Studio")
                .font(.largeTitle.bold())

            HStack(spacing: 8) {
                ProgressView()
                Text("Discovering network…")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyContent: some View {
        VStack(spacing: 24) {
            Image("MiloGreeting")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 400)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 8)

            Text("Pricing Studio")
                .font(.largeTitle.bold())

            Text("Add operators or authorities to see the network topology.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Canvas Rendering

    @ViewBuilder
    private func topologyCanvas(size: CGSize) -> some View {
        let originalChildCounts = collectChildCounts(roots: topologyVM.roots)
        let visibleRoots = topologyVM.roots.map { applyCollapse(to: $0) }
        let layout = TreeLayout.layout(roots: visibleRoots, canvasSize: size)

        ZStack {
            // Edges
            ForEach(layout.edges, id: \.id) { edge in
                Path { path in
                    let from = edge.from
                    let to = edge.to
                    let midY = (from.y + to.y) / 2
                    path.move(to: from)
                    path.addCurve(
                        to: to,
                        control1: CGPoint(x: from.x, y: midY),
                        control2: CGPoint(x: to.x, y: midY)
                    )
                }
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1.5)
            }

            // Nodes
            ForEach(layout.nodes, id: \.node.id) { positioned in
                let descendantCount = originalChildCounts[positioned.node.id] ?? 0
                nodeView(
                    positioned.node,
                    isSelected: selectedNpub == positioned.node.id,
                    hasDescendants: descendantCount > 0,
                    isCollapsed: collapsedNpubs.contains(positioned.node.id),
                    hiddenCount: collapsedNpubs.contains(positioned.node.id) ? descendantCount : 0,
                    onToggleCollapse: {
                        toggleCollapse(positioned.node.id)
                    }
                )
                    .position(positioned.position)
                    .onTapGesture {
                        selectedNpub = positioned.node.id
                        onNodeSelected?(positioned.node.id, positioned.node.tier)
                    }
            }

        }
        .frame(
            width: max(size.width, layout.canvasSize.width),
            height: max(size.height, layout.canvasSize.height)
        )
    }

    // MARK: - Collapse helpers

    private func toggleCollapse(_ npub: String) {
        if collapsedNpubs.contains(npub) {
            collapsedNpubs.remove(npub)
        } else {
            collapsedNpubs.insert(npub)
        }
    }

    /// Recursively trim children out of any node whose npub is in
    /// `collapsedNpubs` so the layout engine doesn't lay them out.
    private func applyCollapse(to node: TopologyNode) -> TopologyNode {
        if collapsedNpubs.contains(node.id) {
            return TopologyNode(id: node.id, displayName: node.displayName, tier: node.tier, children: [])
        }
        let trimmed = node.children.map { applyCollapse(to: $0) }
        return TopologyNode(id: node.id, displayName: node.displayName, tier: node.tier, children: trimmed)
    }

    /// Count of total descendants per node id, computed from the un-trimmed
    /// roots so collapsed nodes can show how many they're hiding.
    private func collectChildCounts(roots: [TopologyNode]) -> [String: Int] {
        var counts: [String: Int] = [:]
        @discardableResult
        func walk(_ n: TopologyNode) -> Int {
            var total = 0
            for c in n.children {
                total += 1 + walk(c)
            }
            counts[n.id] = total
            return total
        }
        for r in roots { walk(r) }
        return counts
    }

    private var oracleNode: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(NetworkTier.oracle.color.opacity(showingOracleChat ? 1.0 : 0.2))
                    .frame(width: 44, height: 44)

                Text("🦉")
                    .font(.system(size: 22))
            }
            .onTapGesture {
                withAnimation { showingOracleChat.toggle() }
            }

            Text("Oracle")
                .font(.caption2.bold())
                .foregroundStyle(NetworkTier.oracle.color)
        }
    }

    private func nodeView(
        _ node: TopologyNode,
        isSelected: Bool,
        hasDescendants: Bool = false,
        isCollapsed: Bool = false,
        hiddenCount: Int = 0,
        onToggleCollapse: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    Circle()
                        .fill(node.tier.color.opacity(isSelected ? 1.0 : 0.2))
                        .frame(width: node.tier.nodeRadius * 2, height: node.tier.nodeRadius * 2)

                    if isSelected {
                        Circle()
                            .strokeBorder(node.tier.color, lineWidth: 3)
                            .frame(width: node.tier.nodeRadius * 2 + 6, height: node.tier.nodeRadius * 2 + 6)
                    }

                    Image(systemName: node.tier.iconName)
                        .font(.system(size: node.tier.nodeRadius * 0.7))
                        .foregroundStyle(isSelected ? .white : node.tier.color)
                }

                // Disclosure badge — only on nodes that have descendants.
                // Tappable independently of the node body so it never
                // interferes with selection.
                if hasDescendants, let onToggleCollapse {
                    disclosureBadge(
                        isCollapsed: isCollapsed,
                        hiddenCount: hiddenCount,
                        tier: node.tier,
                        onTap: onToggleCollapse
                    )
                    .offset(x: 6, y: 6)
                }
            }

            Text(node.displayName)
                .font(.caption2)
                .foregroundStyle(isSelected ? node.tier.color : .primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 80)
        }
    }

    private func disclosureBadge(
        isCollapsed: Bool,
        hiddenCount: Int,
        tier: NetworkTier,
        onTap: @escaping () -> Void
    ) -> some View {
        let label: String = isCollapsed && hiddenCount > 0 ? "+\(hiddenCount)" : ""
        return HStack(spacing: 2) {
            Image(systemName: isCollapsed ? "plus.circle.fill" : "minus.circle.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white, tier.color)
                .background(Circle().fill(Color(.systemBackground)))
            if !label.isEmpty {
                Text(label)
                    .font(.caption2.bold().monospacedDigit())
                    .foregroundStyle(tier.color)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(Color(.systemBackground))
                            .overlay(Capsule().stroke(tier.color.opacity(0.6), lineWidth: 0.5))
                    )
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityLabel(isCollapsed ? "Expand subtree (\(hiddenCount) hidden)" : "Collapse subtree")
    }
}

// MARK: - Compact Outline (phone home screen)

/// The network hierarchy as a native, collapsible outline — the compact-width
/// alternative to the spatial canvas, which needs a wide canvas to pan. Same
/// TopologyNode tree, same tap-to-select contract.
private struct TopologyListView: View {
    let roots: [TopologyNode]
    var onNodeSelected: (String, NetworkTier) -> Void

    var body: some View {
        List {
            ForEach(roots) { root in
                OutlineGroup(root, children: \.childrenOrNil) { node in
                    Button {
                        onNodeSelected(node.id, node.tier)
                    } label: {
                        TopologyNodeRow(node: node)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

private struct TopologyNodeRow: View {
    let node: TopologyNode

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(node.tier.color.opacity(0.2))
                    .frame(width: 30, height: 30)
                Image(systemName: node.tier.iconName)
                    .font(.system(size: 13))
                    .foregroundStyle(node.tier.color)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(node.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(node.tier.listLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

private extension TopologyNode {
    /// OutlineGroup wants nil (not an empty array) to mark a leaf.
    var childrenOrNil: [TopologyNode]? { children.isEmpty ? nil : children }
}

private extension NetworkTier {
    var listLabel: String {
        switch self {
        case .oracle: return "Oracle"
        case .primeAuthority: return "Prime Authority"
        case .authority: return "Authority"
        case .operator: return "Operator"
        }
    }
}

// MARK: - Tree Layout Engine

enum TreeLayout {
    struct PositionedNode {
        let node: TopologyNode
        let position: CGPoint
    }

    struct Edge: Identifiable {
        let id: String
        let from: CGPoint
        let to: CGPoint
    }

    struct LayoutResult {
        let nodes: [PositionedNode]
        let edges: [Edge]
        let canvasSize: CGSize
    }

    static func layout(roots: [TopologyNode], canvasSize: CGSize) -> LayoutResult {
        let horizontalSpacing: CGFloat = 100
        let verticalSpacing: CGFloat = 120
        let topPadding: CGFloat = 60
        let leftPadding: CGFloat = 60

        var positionedNodes: [PositionedNode] = []
        var edges: [Edge] = []
        var currentX: CGFloat = leftPadding

        for root in roots {
            let (nodes, edgeList, width) = layoutSubtree(
                node: root,
                x: currentX,
                y: topPadding,
                horizontalSpacing: horizontalSpacing,
                verticalSpacing: verticalSpacing
            )
            positionedNodes.append(contentsOf: nodes)
            edges.append(contentsOf: edgeList)
            currentX += width + horizontalSpacing
        }

        let maxX = positionedNodes.map(\.position.x).max() ?? 0
        let maxY = positionedNodes.map(\.position.y).max() ?? 0
        let treeWidth = maxX + leftPadding
        let treeHeight = maxY + topPadding
        let finalWidth = max(canvasSize.width, treeWidth + leftPadding)
        let finalHeight = max(canvasSize.height, treeHeight + topPadding)

        // Center the tree in the canvas
        let offsetX = max(0, (finalWidth - treeWidth) / 2 - leftPadding)
        let offsetY = max(0, (finalHeight - treeHeight) / 2 - topPadding)
        let centeredNodes = positionedNodes.map { pn in
            PositionedNode(node: pn.node, position: CGPoint(x: pn.position.x + offsetX, y: pn.position.y + offsetY))
        }
        let centeredEdges = edges.map { e in
            Edge(id: e.id,
                 from: CGPoint(x: e.from.x + offsetX, y: e.from.y + offsetY),
                 to: CGPoint(x: e.to.x + offsetX, y: e.to.y + offsetY))
        }

        return LayoutResult(
            nodes: centeredNodes,
            edges: centeredEdges,
            canvasSize: CGSize(width: finalWidth, height: finalHeight)
        )
    }

    /// Returns (positioned nodes, edges, subtree width)
    private static func layoutSubtree(
        node: TopologyNode,
        x: CGFloat,
        y: CGFloat,
        horizontalSpacing: CGFloat,
        verticalSpacing: CGFloat
    ) -> ([PositionedNode], [Edge], CGFloat) {
        guard !node.children.isEmpty else {
            let positioned = PositionedNode(node: node, position: CGPoint(x: x, y: y))
            return ([positioned], [], horizontalSpacing)
        }

        var allNodes: [PositionedNode] = []
        var allEdges: [Edge] = []
        var childX = x
        var childWidths: CGFloat = 0

        for child in node.children {
            let (childNodes, childEdges, childWidth) = layoutSubtree(
                node: child,
                x: childX,
                y: y + verticalSpacing,
                horizontalSpacing: horizontalSpacing,
                verticalSpacing: verticalSpacing
            )
            allNodes.append(contentsOf: childNodes)
            allEdges.append(contentsOf: childEdges)
            childX += childWidth
            childWidths += childWidth
        }

        // Center parent over children
        let childIds = Set(node.children.map(\.id))
        let directChildPositions = allNodes.filter { childIds.contains($0.node.id) }.map(\.position.x)
        let parentX = directChildPositions.isEmpty
            ? x
            : (directChildPositions.min()! + directChildPositions.max()!) / 2
        let parentPos = CGPoint(x: parentX, y: y)

        let parentNode = PositionedNode(node: node, position: parentPos)
        allNodes.insert(parentNode, at: 0)

        // Edges from parent to direct children
        for child in node.children {
            if let childPos = allNodes.first(where: { $0.node.id == child.id })?.position {
                allEdges.append(Edge(
                    id: "\(node.id)->\(child.id)",
                    from: parentPos,
                    to: childPos
                ))
            }
        }

        return (allNodes, allEdges, childWidths)
    }
}

