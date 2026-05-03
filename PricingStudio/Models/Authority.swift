import Foundation
import SwiftData

@Model
final class Authority: PricingTarget {
    static let primeNpub = "npub1l94pd4qu4eszrl6ek032ftcnsu3tt9a7xvq2zp7eaxeklp6mrpzssmq8pf"
    static let primeDisplayName = "DPYC Prime Authority"

    var npub: String = ""
    var displayName: String = ""
    var nip05: String?
    var mcpEndpointURL: String?
    var addedAt: Date = Date()
    var isAutoDiscovered: Bool = false
    /// Npub of the Authority that certifies this one (its parent in the
    /// Honor Chain). When this Authority acts as an Operator paying
    /// `credit_sats` upstream, invoices accrue to the parent. Nil for Prime
    /// or when the parent has not yet been resolved.
    var parentAuthorityNpub: String?

    var isPrime: Bool { npub == Self.primeNpub }

    init(npub: String, displayName: String, nip05: String? = nil, mcpEndpointURL: String? = nil, isAutoDiscovered: Bool = false, parentAuthorityNpub: String? = nil) {
        self.npub = npub
        self.displayName = displayName
        self.nip05 = nip05
        self.mcpEndpointURL = mcpEndpointURL
        self.addedAt = Date()
        self.isAutoDiscovered = isAutoDiscovered
        self.parentAuthorityNpub = parentAuthorityNpub
    }

    static func ensurePrimeExists(in context: ModelContext) {
        let descriptor = FetchDescriptor<Authority>(predicate: #Predicate { $0.npub == primeNpub })
        let existing = (try? context.fetch(descriptor)) ?? []
        if existing.isEmpty {
            let prime = Authority(npub: primeNpub, displayName: primeDisplayName)
            prime.addedAt = Date.distantPast // sorts first
            context.insert(prime)
        }
    }
}
