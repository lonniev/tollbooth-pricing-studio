import Foundation

/// A lightweight, value-typed representation of an upstream party that an
/// actor pays into — the kind of party `account_statement` queries are
/// directed at. Plain struct (no SwiftData dependency) so it can be safely
/// constructed each render without identity instability or unmanaged
/// `@Model` lifecycle quirks.
struct InvoiceSource: Identifiable, Hashable, Sendable {
    let npub: String
    let displayName: String
    let mcpEndpointURL: String?
    var id: String { npub }
}

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
    ) -> [InvoiceSource]
}

// MARK: - Role types

struct PatronRole: PaymentActor {
    let entity: Patron
    var npub: String { entity.npub }
    var displayName: String { entity.displayName }

    func invoiceSources(
        authorities: [Authority],
        operators: [Operator]
    ) -> [InvoiceSource] {
        operators.map(\.asInvoiceSource)
    }
}

struct OperatorRole: PaymentActor {
    let entity: Operator
    var npub: String { entity.npub }
    var displayName: String { entity.displayName }

    func invoiceSources(
        authorities: [Authority],
        operators: [Operator]
    ) -> [InvoiceSource] {
        guard let authNpub = entity.authorityNpub,
              let authority = authorities.first(where: { $0.npub == authNpub }) else {
            return []
        }
        return [authority.asInvoiceSource]
    }
}

struct StandardAuthorityRole: PaymentActor {
    let entity: Authority
    var npub: String { entity.npub }
    var displayName: String { entity.displayName }

    func invoiceSources(
        authorities: [Authority],
        operators: [Operator]
    ) -> [InvoiceSource] {
        guard let parentNpub = entity.parentAuthorityNpub,
              let parent = authorities.first(where: { $0.npub == parentNpub }) else {
            return []
        }
        return [parent.asInvoiceSource]
    }
}

struct PenultimateAuthorityRole: PaymentActor {
    let entity: Authority
    var npub: String { entity.npub }
    var displayName: String { entity.displayName }

    func invoiceSources(
        authorities: [Authority],
        operators: [Operator]
    ) -> [InvoiceSource] {
        [entity.asInvoiceSource]
    }
}

// MARK: - Factory extensions

extension Patron {
    func asRole() -> PaymentActor { PatronRole(entity: self) }
}

extension Operator {
    func asRole() -> PaymentActor { OperatorRole(entity: self) }

    var asInvoiceSource: InvoiceSource {
        InvoiceSource(npub: npub, displayName: displayName, mcpEndpointURL: mcpEndpointURL)
    }
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

    var asInvoiceSource: InvoiceSource {
        InvoiceSource(npub: npub, displayName: displayName, mcpEndpointURL: mcpEndpointURL)
    }
}
