import Foundation

/// An entity that has upstream payment relationships in the Honor Chain.
///
/// `invoiceSources` returns the upstream MCPs whose `account_statement`
/// holds this actor's purchase invoices:
///
/// - Patron pays each Operator → many sources.
/// - Operator pays its Authority via `certify_sats` → one source (parent).
/// - Standard Authority pays its parent Authority via `certify_sats` → one
///   source (parent).
/// - Penultimate Authority self-funds via direct BTCPay (parent is Prime,
///   which runs no tollbooth-authority MCP) → one source (self). This is
///   the recursion terminator.
///
/// Role classification happens once via `entity.asRole()`; from there the
/// behavior is polymorphic, with no `if isPenultimate` branches at the
/// call sites.
protocol PaymentActor {
    var npub: String { get }
    var displayName: String { get }
    func invoiceSources(
        authorities: [Authority],
        operators: [Operator]
    ) -> [Operator]
}

// MARK: - Role types

struct PatronRole: PaymentActor {
    let entity: Patron
    var npub: String { entity.npub }
    var displayName: String { entity.displayName }

    func invoiceSources(
        authorities: [Authority],
        operators: [Operator]
    ) -> [Operator] {
        operators
    }
}

struct OperatorRole: PaymentActor {
    let entity: Operator
    var npub: String { entity.npub }
    var displayName: String { entity.displayName }

    func invoiceSources(
        authorities: [Authority],
        operators: [Operator]
    ) -> [Operator] {
        guard let authNpub = entity.authorityNpub,
              let authority = authorities.first(where: { $0.npub == authNpub }) else {
            return []
        }
        return [authorityAsSource(authority)]
    }
}

struct StandardAuthorityRole: PaymentActor {
    let entity: Authority
    var npub: String { entity.npub }
    var displayName: String { entity.displayName }

    func invoiceSources(
        authorities: [Authority],
        operators: [Operator]
    ) -> [Operator] {
        guard let parentNpub = entity.parentAuthorityNpub,
              let parent = authorities.first(where: { $0.npub == parentNpub }) else {
            return []
        }
        return [authorityAsSource(parent)]
    }
}

struct PenultimateAuthorityRole: PaymentActor {
    let entity: Authority
    var npub: String { entity.npub }
    var displayName: String { entity.displayName }

    func invoiceSources(
        authorities: [Authority],
        operators: [Operator]
    ) -> [Operator] {
        [authorityAsSource(entity)]
    }
}

// MARK: - Factory extensions

extension Patron {
    func asRole() -> PaymentActor { PatronRole(entity: self) }
}

extension Operator {
    func asRole() -> PaymentActor { OperatorRole(entity: self) }
}

extension Authority {
    /// True when this Authority's parent is Prime — the recursion terminator.
    /// Prime hosts the Oracle, not a tollbooth-authority service, so a
    /// penultimate Authority cannot pay `certify_sats` upstream and instead
    /// self-funds via direct BTCPay.
    var isPenultimate: Bool {
        parentAuthorityNpub == Self.primeNpub
    }

    func asRole() -> PaymentActor {
        isPenultimate
            ? PenultimateAuthorityRole(entity: self)
            : StandardAuthorityRole(entity: self)
    }
}

// MARK: - Wrapping helper

/// `InvoiceListView` and `PatronAccountViewModel.forceRefresh` both take
/// `[Operator]` as the canonical "thing with npub + endpoint + name". When
/// the actual upstream party is an Authority (Operator's parent, or an
/// Authority's parent, or a penultimate's self), wrap it into an
/// Operator-shaped value here. Single helper, single place.
private func authorityAsSource(_ authority: Authority) -> Operator {
    let source = Operator(npub: authority.npub, displayName: authority.displayName)
    source.mcpEndpointURL = authority.mcpEndpointURL
    return source
}
