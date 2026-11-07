import CryptoKit
import Foundation
import UserNotifications

/// Wrist Approval (step 4): classifies incoming Secure Courier DMs that are
/// npub-proof challenges, precomputes the approval reply, and defines the
/// notification category whose Approve/Reject buttons mirror to the Apple
/// Watch. Pure functions only — the posting and the sending live in
/// DMPollingService and the notification delegate.
public enum ProofApprovalService {

    // MARK: - Identifiers

    public static let categoryId = "courier-proof-approval"
    public static let approveActionId = "approve"
    public static let rejectActionId = "reject"
    public static let defaultDuration = "2h"

    /// Notification-group ("thread") identifier that isolates each approval
    /// banner into its own group. Apple Watch (and iOS) group every delivered
    /// notification that shares a `threadIdentifier`, and dismissing one member
    /// of a group purges the WHOLE group. Left unset, every banner this app
    /// posts shares the empty default thread — so dismissing an ordinary Nostr
    /// DM banner on the watch also swept away an actionable Approval Request
    /// (issue #83). A per-nonce thread keeps each approval independently
    /// dismissible and never collateral to a DM (or sibling-approval) dismissal.
    ///
    /// The token is hashed, not embedded raw: `threadIdentifier` can surface in
    /// unified system logs / sysdiagnose and is readable in-process via
    /// `getDeliveredNotifications`, a wider exposure than the `userInfo` payload.
    /// A SHA-256 digest preserves per-token grouping without carrying the raw
    /// anti-replay nonce into that channel.
    public static func approvalThreadIdentifier(nonce: String) -> String {
        let hex = SHA256.hash(data: Data(nonce.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(16)
        return "\(categoryId)-\(hex)"
    }

    // MARK: - Classifier

    /// A courier DM that a single tap can safely approve.
    public struct ProofChallenge: Sendable {
        public let payload: CourierPayload
        public var nonce: String { payload.nonce }
        public var pinnedRelay: URL { payload.rendezvousRelay }

        public init(payload: CourierPayload) {
            self.payload = payload
        }
    }

    /// The field an approval reply uses to say how long the proof is kept.
    public static let durationKey = "cache_duration"

    /// Decide whether a DM is a one-tap-approvable request.
    ///
    /// It must be a courier request whose form says it is an approval, with
    /// no secret field. A watch tap can affirm; it can never supply a secret,
    /// so a credential form (or an approval that asks for one) is left for
    /// the in-app form.
    public static func classify(tags: [[String]], requestId: String) -> ProofChallenge? {
        guard let payload = CourierPayload.parse(tags: tags, requestId: requestId),
              payload.isApproval,
              !payload.fields.contains(where: { $0.property.isSecret }) else { return nil }
        return ProofChallenge(payload: payload)
    }

    // MARK: - Reply Builder

    /// The reply the Approve button sends: the approval answered, with how
    /// long to keep the proof, as the courier's JSON reply.
    public static func buildApprovalReply(_ challenge: ProofChallenge, duration: String = defaultDuration) -> String {
        challenge.payload.approved().setting(durationKey, to: duration).replyContent()
    }

    // MARK: - userInfo Codec

    /// Everything the notification-action handler needs, captured at post
    /// time so the handler never reloads conversations or re-parses DMs.
    /// The reply content embeds the one-time nonce; local-notification
    /// userInfo never leaves the device/watch pairing.
    public struct ApprovalRequest: Equatable, Sendable {
        public let signerNpub: String
        public let replyToHex: String
        public let pinnedRelay: URL
        public let replyContent: String
        public let eventId: String
        /// The request's rumor id, quoted in the reply's `e` tag.
        public let requestId: String

        /// The reply's private rumor tags.
        public var replyTags: [[String]] {
            requestId.isEmpty ? [] : [["e", requestId]]
        }

        private enum Key {
            static let version = "proofApproval.v"
            static let signerNpub = "proofApproval.signerNpub"
            static let replyToHex = "proofApproval.replyToHex"
            static let pinnedRelay = "proofApproval.pinnedRelay"
            static let replyContent = "proofApproval.replyContent"
            static let eventId = "proofApproval.eventId"
            static let requestId = "proofApproval.requestId"
        }

        public var userInfo: [String: Any] {
            [
                Key.version: 2,
                Key.signerNpub: signerNpub,
                Key.replyToHex: replyToHex,
                Key.pinnedRelay: pinnedRelay.absoluteString,
                Key.replyContent: replyContent,
                Key.eventId: eventId,
                Key.requestId: requestId,
            ]
        }

        public init(signerNpub: String, replyToHex: String, pinnedRelay: URL, replyContent: String, eventId: String, requestId: String) {
            self.signerNpub = signerNpub
            self.replyToHex = replyToHex
            self.pinnedRelay = pinnedRelay
            self.replyContent = replyContent
            self.eventId = eventId
            self.requestId = requestId
        }

        public init?(userInfo: [AnyHashable: Any]) {
            guard (userInfo[Key.version] as? Int) == 2,
                  let signerNpub = userInfo[Key.signerNpub] as? String,
                  let replyToHex = userInfo[Key.replyToHex] as? String,
                  let relayText = userInfo[Key.pinnedRelay] as? String,
                  let pinnedRelay = URL(string: relayText),
                  let replyContent = userInfo[Key.replyContent] as? String,
                  let eventId = userInfo[Key.eventId] as? String,
                  let requestId = userInfo[Key.requestId] as? String else { return nil }
            self.signerNpub = signerNpub
            self.replyToHex = replyToHex
            self.pinnedRelay = pinnedRelay
            self.replyContent = replyContent
            self.eventId = eventId
            self.requestId = requestId
        }
    }

    // MARK: - Notification Category

    /// Approve/Reject actions on the challenge banner.
    ///
    /// - **Reject** runs in the background with no unlock — safe direction,
    ///   frictionless even while the phone is locked (`CourierBridgeDoctrine`
    ///   `.rejectWhileLocked`).
    /// - **Approve** requires device unlock (`.authenticationRequired`) so a
    ///   wrist tap cannot silently grant while the phone is locked
    ///   (`CourierBridgeDoctrine` `.acceptRequiresUnlock`, design/courier-bridge.md
    ///   §5). No `.foreground` — once unlocked, the reply still sends from the
    ///   background using the precomputed userInfo payload.
    public static func makeCategory() -> UNNotificationCategory {
        let approve = UNNotificationAction(
            identifier: approveActionId,
            title: "Approve · 2 hours",
            options: [.authenticationRequired]
        )
        let reject = UNNotificationAction(
            identifier: rejectActionId,
            title: "Reject",
            options: [.destructive]
        )
        return UNNotificationCategory(
            identifier: categoryId,
            actions: [approve, reject],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
    }
}
