import SwiftData
import XCTest
@testable import PricingStudio

@MainActor
final class EntityDeduplicatorTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() async throws {
        let schema = Schema([Operator.self, Patron.self, Authority.self, Contact.self, Campaign.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
    }

    override func tearDown() async throws {
        container = nil
    }

    private func fetchAll<T: PersistentModel>(_ type: T.Type) -> [T] {
        (try? context.fetch(FetchDescriptor<T>())) ?? []
    }

    // The production crash: each device minted its own Prime via
    // ensurePrimeExists (both stamped distantPast), CloudKit merged them.
    func testCollapsesDuplicatePrimes() {
        for _ in 0..<2 {
            let prime = Authority(npub: Authority.primeNpub, displayName: Authority.primeDisplayName)
            prime.addedAt = Date.distantPast
            context.insert(prime)
        }

        let removed = EntityDeduplicator.dedupeAll(in: context)

        XCTAssertEqual(removed, 1)
        let primes = fetchAll(Authority.self)
        XCTAssertEqual(primes.count, 1)
        XCTAssertTrue(primes[0].isPrime)
    }

    func testOldestRecordWinsAndAbsorbsRicherFields() {
        let older = Authority(npub: "npub1dup", displayName: "Older")
        older.addedAt = Date(timeIntervalSince1970: 1_000)
        let newer = Authority(npub: "npub1dup", displayName: "Newer",
                              mcpEndpointURL: "https://authority.example/mcp",
                              parentAuthorityNpub: "npub1parent")
        newer.addedAt = Date(timeIntervalSince1970: 2_000)
        context.insert(older)
        context.insert(newer)

        EntityDeduplicator.dedupeAll(in: context)

        let survivors = fetchAll(Authority.self)
        XCTAssertEqual(survivors.count, 1)
        let winner = survivors[0]
        XCTAssertEqual(winner.displayName, "Older", "oldest record wins")
        XCTAssertEqual(winner.mcpEndpointURL, "https://authority.example/mcp",
                       "loser donates fields the winner lacks")
        XCTAssertEqual(winner.parentAuthorityNpub, "npub1parent")
    }

    func testWinnerFieldsAreNeverOverwritten() {
        let older = Operator(npub: "npub1op", displayName: "Curated",
                             mcpEndpointURL: "https://real.example/mcp")
        older.addedAt = Date(timeIntervalSince1970: 1_000)
        let newer = Operator(npub: "npub1op", displayName: "Auto",
                             mcpEndpointURL: "https://stale.example/mcp")
        newer.addedAt = Date(timeIntervalSince1970: 2_000)
        context.insert(older)
        context.insert(newer)

        EntityDeduplicator.dedupeAll(in: context)

        let survivors = fetchAll(Operator.self)
        XCTAssertEqual(survivors.count, 1)
        XCTAssertEqual(survivors[0].mcpEndpointURL, "https://real.example/mcp")
    }

    func testDedupesEveryEntityTypeAndCountsRemovals() {
        context.insert(Authority(npub: "npub1a", displayName: "A1"))
        context.insert(Authority(npub: "npub1a", displayName: "A2"))
        context.insert(Operator(npub: "npub1o", displayName: "O1"))
        context.insert(Operator(npub: "npub1o", displayName: "O2"))
        context.insert(Patron(npub: "npub1p", displayName: "P1"))
        context.insert(Patron(npub: "npub1p", displayName: "P2"))
        context.insert(Contact(npub: "npub1c", displayName: "C1"))
        context.insert(Contact(npub: "npub1c", displayName: "C2"))

        let removed = EntityDeduplicator.dedupeAll(in: context)

        XCTAssertEqual(removed, 4)
        XCTAssertEqual(fetchAll(Authority.self).count, 1)
        XCTAssertEqual(fetchAll(Operator.self).count, 1)
        XCTAssertEqual(fetchAll(Patron.self).count, 1)
        XCTAssertEqual(fetchAll(Contact.self).count, 1)
    }

    func testDistinctNpubsAreUntouched() {
        context.insert(Patron(npub: "npub1x", displayName: "X"))
        context.insert(Patron(npub: "npub1y", displayName: "Y"))

        let removed = EntityDeduplicator.dedupeAll(in: context)

        XCTAssertEqual(removed, 0)
        XCTAssertEqual(fetchAll(Patron.self).count, 2)
    }

    func testEmptyStoreIsANoOp() {
        XCTAssertEqual(EntityDeduplicator.dedupeAll(in: context), 0)
    }
}
