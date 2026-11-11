import DPYCAuthKit
import Foundation

/// An app paired to one of Studio's identities over NIP-46. Public data only:
/// the keys that sign stay in the Keychain.
struct NostrConnectSession: Codable, Identifiable, Equatable {
    let clientPubkey: String
    let signerNpub: String
    let signerPubkey: String
    let relays: [URL]
    let appName: String?
    let appURL: String?
    let pairedAt: Date

    var id: String { "\(clientPubkey):\(signerPubkey)" }
    var displayName: String { appName ?? appURL ?? "App \(clientPubkey.prefix(8))" }
}

/// A request waiting for the user to Approve or Reject.
struct NostrConnectApproval: Identifiable {
    let id = UUID()
    let session: NostrConnectSession
    let request: NIP46Request
    let cipher: NIP46.Cipher
    let title: String
    let detail: String
}

/// Studio as a NIP-46 remote signer, foreground only. A site shows a
/// `nostrconnect://` token; the user opens it here and picks an identity;
/// Studio answers that site's requests while it is the active app. Every
/// signature and every encrypt/decrypt asks the user first.
@MainActor @Observable
final class NostrConnectService {
    static let shared = NostrConnectService()

    private(set) var sessions: [NostrConnectSession] = []
    private(set) var pending: [NostrConnectApproval] = []
    /// A token opened or pasted, waiting for the user to pick an identity.
    var pairing: NostrConnectURI?
    var lastError: String?

    private static let storeKey = "nostrConnectSessions"
    private static let maxPending = 20
    private static let maxSeen = 500

    private var connections: [URL: PersistentRelayConnection] = [:]
    private var eventTasks: [URL: Task<Void, Never>] = [:]
    private var seenEventIds: [String] = []
    private var listening = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let saved = try? JSONDecoder().decode([NostrConnectSession].self, from: data) {
            sessions = saved
        }
    }

    // MARK: - Pairing

    /// Open a `nostrconnect://` link or pasted token.
    func open(_ text: String) {
        do {
            pairing = try NostrConnectURI.parse(text)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Pair `uri` with the identity `npub`: answer the app's connect with its
    /// secret, then keep listening for its requests.
    func pair(_ uri: NostrConnectURI, as npub: String) async throws {
        let keys = try Self.keys(for: npub)
        let session = NostrConnectSession(
            clientPubkey: uri.clientPubkey, signerNpub: npub, signerPubkey: keys.pub,
            relays: uri.relays, appName: uri.name, appURL: uri.url, pairedAt: Date()
        )
        let ack = NIP46Response(id: Self.randomId(), result: uri.secret)
        try await send(ack, cipher: .nip44, in: session)

        sessions.removeAll { $0.id == session.id }
        sessions.append(session)
        save()
        pairing = nil
        TrafficLogger.shared.log(.outbound, label: "Nostr Connect",
                                 detail: "paired \(session.displayName)")
        if listening { resubscribe() }
    }

    func disconnect(_ session: NostrConnectSession) {
        sessions.removeAll { $0.id == session.id }
        pending.removeAll { $0.session.id == session.id }
        save()
        if listening { resubscribe() }
    }

    // MARK: - Listening (foreground only)

    func startListening() {
        guard !listening else { return }
        listening = true
        resubscribe()
    }

    func stopListening() {
        listening = false
        for task in eventTasks.values { task.cancel() }
        for conn in connections.values { conn.disconnect() }
        eventTasks = [:]
        connections = [:]
    }

    /// One subscription per relay naming every identity paired through it.
    private func resubscribe() {
        var signersByRelay: [URL: Set<String>] = [:]
        for session in sessions {
            for relay in session.relays { signersByRelay[relay, default: []].insert(session.signerPubkey) }
        }
        for (url, conn) in connections where signersByRelay[url] == nil {
            conn.disconnect()
            eventTasks[url]?.cancel()
            connections[url] = nil
            eventTasks[url] = nil
        }
        let since = Int(Date().timeIntervalSince1970) - 60
        for (url, signers) in signersByRelay {
            let conn = connections[url] ?? makeConnection(url)
            conn.subscribe(subId: "nip46", filters: [[
                "kinds": [NostrEventKind.nostrConnect.rawValue],
                "#p": Array(signers),
                "since": since,
            ]])
        }
    }

    private func makeConnection(_ url: URL) -> PersistentRelayConnection {
        let conn = PersistentRelayConnection(url: url)
        connections[url] = conn
        eventTasks[url] = Task { [weak self] in
            for await event in conn.events {
                await self?.handle(event)
            }
        }
        Task { try? await conn.connect() }
        return conn
    }

    // MARK: - Requests

    private func handle(_ event: NostrEvent) async {
        guard !seenEventIds.contains(event.id) else { return }
        seenEventIds.append(event.id)
        if seenEventIds.count > Self.maxSeen { seenEventIds.removeFirst(seenEventIds.count - Self.maxSeen) }

        let tagged = Set(event.tags.filter { $0.first == "p" && $0.count > 1 }.map { $0[1] })
        // Only the paired app's own key may ask, and only of the identity it paired with.
        guard let session = sessions.first(where: {
            $0.clientPubkey == event.pubkey && tagged.contains($0.signerPubkey)
        }), let keys = try? Self.keys(for: session.signerNpub),
              let decoded = try? NIP46.decryptRequest(event, signerPrivateKeyHex: keys.priv)
        else { return }
        let (request, cipher) = decoded

        TrafficLogger.shared.log(.inbound, label: "Nostr Connect",
                                 detail: "\(session.displayName): \(request.method)")
        switch request.method {
        case "ping":
            await reply(NIP46Response(id: request.id, result: "pong"), cipher, session)
        case "get_public_key":
            await reply(NIP46Response(id: request.id, result: session.signerPubkey), cipher, session)
        case "connect":
            await reply(NIP46Response(id: request.id, result: "ack"), cipher, session)
        case "sign_event", "nip04_encrypt", "nip04_decrypt", "nip44_encrypt", "nip44_decrypt":
            guard let described = Self.describe(request) else {
                await reply(NIP46Response(id: request.id, result: "", error: "invalid params"), cipher, session)
                return
            }
            let (title, detail) = described
            guard pending.count < Self.maxPending else {
                await reply(NIP46Response(id: request.id, result: "", error: "too many pending requests"), cipher, session)
                return
            }
            pending.append(NostrConnectApproval(
                session: session, request: request, cipher: cipher, title: title, detail: detail
            ))
        default:
            await reply(NIP46Response(id: request.id, result: "", error: "unsupported method"), cipher, session)
        }
    }

    /// The user's answer. Leaves the queue at once, so the next request's
    /// sheet can show while this reply is sent.
    func resolve(_ approval: NostrConnectApproval, approve: Bool) {
        pending.removeAll { $0.id == approval.id }
        Task { approve ? await self.approve(approval) : await self.reject(approval) }
    }

    private func approve(_ approval: NostrConnectApproval) async {
        let request = approval.request
        let response: NIP46Response
        do {
            let keys = try Self.keys(for: approval.session.signerNpub)
            let result = try Self.perform(request, keys: keys)
            response = NIP46Response(id: request.id, result: result)
        } catch {
            response = NIP46Response(id: request.id, result: "", error: "could not complete")
        }
        await reply(response, approval.cipher, approval.session)
    }

    private func reject(_ approval: NostrConnectApproval) async {
        await reply(NIP46Response(id: approval.request.id, result: "", error: "rejected by user"),
                    approval.cipher, approval.session)
    }

    private func reply(_ response: NIP46Response, _ cipher: NIP46.Cipher, _ session: NostrConnectSession) async {
        do {
            try await send(response, cipher: cipher, in: session)
        } catch {
            lastError = "Could not answer \(session.displayName)."
        }
    }

    private func send(_ response: NIP46Response, cipher: NIP46.Cipher, in session: NostrConnectSession) async throws {
        let keys = try Self.keys(for: session.signerNpub)
        let event = try NIP46.responseEvent(
            response, to: session.clientPubkey, cipher: cipher,
            signerPrivateKeyHex: keys.priv, signerPublicKeyHex: keys.pub
        )
        let results = await NostrRelayService(relays: session.relays).publish(event)
        guard results.contains(where: { $0.1 }) else { throw NostrConnectError.notDelivered }
    }

    // MARK: - Pure helpers

    /// Carry out an approved request.
    static func perform(_ request: NIP46Request, keys: (priv: String, pub: String)) throws -> String {
        let p = request.params
        switch request.method {
        case "sign_event":
            guard let param = p.first else { throw NostrConnectError.badParams }
            return try NIP46.sign(NIP46.unsignedEvent(from: param), privateKeyHex: keys.priv, publicKeyHex: keys.pub)
        case "nip04_encrypt", "nip04_decrypt", "nip44_encrypt", "nip44_decrypt":
            guard p.count >= 2, p[0].count == 64, p[0].allSatisfy(\.isHexDigit) else {
                throw NostrConnectError.badParams
            }
            let cipher: NIP46.Cipher = request.method.hasPrefix("nip04") ? .nip04 : .nip44
            return request.method.hasSuffix("encrypt")
                ? try NIP46.encrypt(p[1], cipher: cipher, privateKeyHex: keys.priv, peerPublicKeyHex: p[0])
                : try NIP46.decrypt(p[1], cipher: cipher, privateKeyHex: keys.priv, peerPublicKeyHex: p[0])
        default:
            throw NostrConnectError.badParams
        }
    }

    /// What the approval sheet says about a request; nil when its params are unreadable.
    static func describe(_ request: NIP46Request) -> (title: String, detail: String)? {
        switch request.method {
        case "sign_event":
            guard let param = request.params.first,
                  let event = try? NIP46.unsignedEvent(from: param) else { return nil }
            let preview = event.content.isEmpty ? "(no text)" : String(event.content.prefix(280))
            return ("Sign \(kindName(event.kind))", preview)
        case "nip04_encrypt", "nip44_encrypt", "nip04_decrypt", "nip44_decrypt":
            guard request.params.count >= 2, let npub = try? NostrKeyService.npubFromHex(request.params[0]) else {
                return nil
            }
            let verb = request.method.hasSuffix("encrypt") ? "Encrypt a message to" : "Read a message from"
            return (verb, String(npub.prefix(16)) + "…")
        default:
            return nil
        }
    }

    static func kindName(_ kind: Int) -> String {
        switch kind {
        case 0: return "your profile"
        case 1: return "a note"
        case 3: return "your follow list"
        case 7: return "a reaction"
        case 9734: return "a zap request"
        case 22242: return "a login"
        case 27235: return "a web request (NIP-98)"
        case 30023: return "an article"
        default: return "a kind-\(kind) event"
        }
    }

    private static func keys(for npub: String) throws -> (priv: String, pub: String) {
        guard let nsec = KeychainService.loadNsec(forNpub: npub) else { throw NostrConnectError.noKey }
        return (try NostrKeyService.privateKeyHexFromNsec(nsec), try NostrKeyService.publicKeyHexFromNpub(npub))
    }

    private static func randomId() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }
}

enum NostrConnectError: LocalizedError {
    case noKey
    case badParams
    case notDelivered

    var errorDescription: String? {
        switch self {
        case .noKey: return "Studio holds no signing key for that identity."
        case .badParams: return "The request could not be read."
        case .notDelivered: return "No relay accepted the reply."
        }
    }
}
