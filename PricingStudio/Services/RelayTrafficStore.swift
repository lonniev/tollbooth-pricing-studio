import Foundation

/// Device-local, per-relay DM traffic counters bucketed by the hour.
///
/// Records how many DMs were **sent to** and **received from** each relay over
/// time so the Relays view can show which relays are actually carrying traffic.
/// Persisted to UserDefaults — deliberately NOT SwiftData/CloudKit: these are
/// per-device diagnostics and must not sync across the user's devices.
@Observable @MainActor
final class RelayTrafficStore {
    static let shared = RelayTrafficStore()

    enum Direction { case sent, received }

    struct Bucket: Identifiable {
        let date: Date        // start of the hour
        var sent: Int
        var received: Int
        var id: Date { date }
        var total: Int { sent + received }
    }

    private static let storageKey = "relay.traffic.v1"
    private static let retentionHours = 24 * 7          // keep a week
    private static let secondsPerHour: TimeInterval = 3600

    /// relay URL string → hour-epoch (String key for JSON) → [sent, received].
    private var storage: [String: [String: [Int]]]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: [String: [Int]]].self, from: data) {
            storage = decoded
        } else {
            storage = [:]
        }
    }

    private func hourKey(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970 / Self.secondsPerHour)
    }

    /// Record one (or more) DM events on a relay in the current hour bucket.
    func record(relay: String, direction: Direction, count: Int = 1) {
        guard count > 0, !relay.isEmpty else { return }
        let key = String(hourKey(Date()))
        var byHour = storage[relay] ?? [:]
        var pair = byHour[key] ?? [0, 0]
        if direction == .sent { pair[0] += count } else { pair[1] += count }
        byHour[key] = pair
        storage[relay] = byHour
        evictOld(relay: relay)
        persist()
    }

    private func evictOld(relay: String) {
        guard var byHour = storage[relay] else { return }
        let cutoff = hourKey(Date()) - Self.retentionHours
        byHour = byHour.filter { (Int($0.key) ?? 0) >= cutoff }
        storage[relay] = byHour
    }

    /// A continuous, zero-filled hourly series for the last `hours` (oldest first).
    func series(for relay: String, hours: Int = 24) -> [Bucket] {
        let nowHour = hourKey(Date())
        let byHour = storage[relay] ?? [:]
        return (0..<hours).reversed().map { offset -> Bucket in
            let h = nowHour - offset
            let date = Date(timeIntervalSince1970: TimeInterval(h) * Self.secondsPerHour)
            let pair = byHour[String(h)] ?? [0, 0]
            return Bucket(date: date, sent: pair.first ?? 0, received: pair.count > 1 ? pair[1] : 0)
        }
    }

    /// Lifetime totals retained in the window for a relay.
    func totals(for relay: String) -> (sent: Int, received: Int) {
        let byHour = storage[relay] ?? [:]
        var sent = 0, received = 0
        for pair in byHour.values {
            sent += pair.first ?? 0
            received += pair.count > 1 ? pair[1] : 0
        }
        return (sent, received)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(storage) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
