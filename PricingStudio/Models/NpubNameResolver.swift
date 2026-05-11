import Foundation
import SwiftData

/// Resolve an npub to a human-readable display name by searching every
/// SwiftData-backed actor registry the app maintains.
///
/// Lookup order — `Patron` → `Operator` → `Authority` → `Contact`. First
/// match wins. Returns `nil` if no actor with this npub is known; callers
/// should fall back to a raw / truncated npub in that case.
///
/// Used by any UI that receives a raw npub for an actor whose identity is
/// likely already in one of the app's registries (Top-Off sheets, invoice
/// rows, etc.).
enum NpubNameResolver {
    @MainActor
    static func displayName(for npub: String, in context: ModelContext) -> String? {
        let trimmed = npub.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if let p = fetchFirst(Patron.self, npub: trimmed, in: context) {
            return nonEmptyName(p.displayName)
        }
        if let o = fetchFirst(Operator.self, npub: trimmed, in: context) {
            return nonEmptyName(o.displayName)
        }
        if let a = fetchFirst(Authority.self, npub: trimmed, in: context) {
            return nonEmptyName(a.displayName)
        }
        if let c = fetchFirst(Contact.self, npub: trimmed, in: context) {
            return nonEmptyName(c.displayName)
        }
        return nil
    }

    // MARK: - Helpers

    @MainActor
    private static func fetchFirst<T>(_ type: T.Type, npub: String, in context: ModelContext) -> T?
        where T: PersistentModel
    {
        // Each model exposes `var npub: String` and is annotated @Model.
        // We can't share a single Predicate across types because SwiftData
        // requires the predicate to be typed to the specific PersistentModel;
        // this little redirect keeps the call sites symmetric.
        if type == Patron.self {
            let d = FetchDescriptor<Patron>(predicate: #Predicate { $0.npub == npub })
            return (try? context.fetch(d).first) as? T
        }
        if type == Operator.self {
            let d = FetchDescriptor<Operator>(predicate: #Predicate { $0.npub == npub })
            return (try? context.fetch(d).first) as? T
        }
        if type == Authority.self {
            let d = FetchDescriptor<Authority>(predicate: #Predicate { $0.npub == npub })
            return (try? context.fetch(d).first) as? T
        }
        if type == Contact.self {
            let d = FetchDescriptor<Contact>(predicate: #Predicate { $0.npub == npub })
            return (try? context.fetch(d).first) as? T
        }
        return nil
    }

    /// Treat blank display names as "no name" — never return whitespace.
    private static func nonEmptyName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
