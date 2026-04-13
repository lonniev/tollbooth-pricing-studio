import SwiftUI
import SwiftData

struct NetworkTopologyView: View {
    @Query(sort: \Authority.addedAt) private var authorities: [Authority]
    @Query(sort: \Operator.addedAt) private var operators: [Operator]
    @State private var topologyVM = TopologyViewModel()
    @State private var selectedNpub: String?
    @State private var showingOracleChat = false

    var onNodeSelected: ((String, NetworkTier) -> Void)?
    var onOraclePrompt: ((String) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            graphContent
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
                Text("DPYC Honor Chain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            legendView
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
        let layout = TreeLayout.layout(roots: topologyVM.roots, canvasSize: size)

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
                nodeView(positioned.node, isSelected: selectedNpub == positioned.node.id)
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

    private func nodeView(_ node: TopologyNode, isSelected: Bool) -> some View {
        VStack(spacing: 4) {
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

            Text(node.displayName)
                .font(.caption2)
                .foregroundStyle(isSelected ? node.tier.color : .primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 80)
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

