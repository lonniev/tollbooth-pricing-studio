import SwiftUI
import SwiftData

struct AuthorityDetailView: View {
    let authority: Authority
    @Bindable var pricingVM: PricingViewModel
    var authorityVM: AuthorityCollectionViewModel?
    var onOperatorSelected: ((Operator) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            authorityHeader
            Divider()
            adoptOperatorButton
            Divider()
            connectedOperatorsSection
            Divider()
            pricingSection
        }
        .navigationTitle(authority.displayName)
    }

    // MARK: - Adopt Operator

    @ViewBuilder
    private var adoptOperatorButton: some View {
        if authority.mcpEndpointURL != nil, let vm = authorityVM {
            Button {
                vm.requestAdopt(authority)
            } label: {
                Label("Adopt Operator", systemImage: "person.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Header

    private var authorityHeader: some View {
        VStack(spacing: 12) {
            Image(systemName: "building.columns.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text(authority.displayName)
                .font(.title2.bold())

            Text(authority.npub)
                .font(.caption)
                .monospaced()
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if authority.isAutoDiscovered {
                Label("Auto-discovered", systemImage: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    // MARK: - Connected Operators

    private var connectedOperatorsSection: some View {
        ConnectedOperatorsList(authorityNpub: authority.npub, onOperatorSelected: onOperatorSelected)
    }

    // MARK: - Pricing

    @ViewBuilder
    private var pricingSection: some View {
        if authority.mcpEndpointURL != nil {
            PricingDetailView(target: authority, viewModel: pricingVM)
                .frame(maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "No MCP Endpoint",
                systemImage: "link.badge.plus",
                description: Text("This authority's MCP endpoint hasn't been discovered yet.")
            )
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Connected Operators List

/// Shows operators whose authorityNpub matches this authority.
private struct ConnectedOperatorsList: View {
    let authorityNpub: String
    var onOperatorSelected: ((Operator) -> Void)?
    @Query private var allOperators: [Operator]

    init(authorityNpub: String, onOperatorSelected: ((Operator) -> Void)? = nil) {
        self.authorityNpub = authorityNpub
        self.onOperatorSelected = onOperatorSelected
        self._allOperators = Query(sort: \Operator.addedAt)
    }

    private var connectedOperators: [Operator] {
        allOperators.filter { $0.authorityNpub == authorityNpub }
    }

    var body: some View {
        if connectedOperators.isEmpty {
            Text("No connected operators")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connected Operators")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.top, 8)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(connectedOperators) { op in
                            Button {
                                onOperatorSelected?(op)
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: "server.rack")
                                        .font(.title3)
                                        .foregroundStyle(.orange)
                                    Text(op.displayName)
                                        .font(.caption2)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
                                .frame(width: 80)
                                .padding(.vertical, 6)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 8)
            }
        }
    }
}
