import CryptoKit
import Foundation
import UserNotifications

/// Wrist Approval (step 4): classifies incoming Secure Courier DMs that are
/// npub-proof challenges, precomputes the approval reply, and defines the
/// notification category whose Approve/Reject buttons mirror to the Apple
/// Watch. Pure functions only — the posting and the sending live in
/// DMPollingService and the notification delegate.
enum ProofApprovalService {

    // MARK: - Identifiers

    static let categoryId = "courier-proof-approval"
    static let approveActionId = "approve"
    static let rejectActionId = "reject"
    static let defaultDuration = "2h"

    /// Notification-group ("thread") identifier that isolates each approval
    /// banner into its own group. Apple Watch (and iOS) group every delivered
    /// notification that shares a `threadIdentifier`, and dismissing one member
    /// of a group purges the WHOLE group. Left unset, every banner this app
    /// posts shares the empty default thread — so dismissing an ordinary Nostr
    /// DM banner on the watch also swept away an actionable Approval Request
    /// (issue #83). A per-dpop_token thread keeps each approval independently
    /// dismissible and never collateral to a DM (or sibling-approval) dismissal.
    ///
    /// The token is hashed, not embedded raw: `threadIdentifier` can surface in
    /// unified system logs / sysdiagnose and is readable in-process via
    /// `getDeliveredNotifications`, a wider exposure than the `userInfo` payload.
    /// A SHA-256 digest preserves per-token grouping without carrying the raw
    /// anti-replay nonce into that channel.
    static func approvalThreadIdentifier(dpopToken: String) -> String {
        let hex = SHA256.hash(data: Data(dpopToken.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(16)
        return "\(categoryId)-\(hex)"
    }

    // MARK: - Classifier

    /// A courier DM that a single tap can safely approve.
    struct ProofChallenge {
        let payload: CourierPayload
        let dpopToken: String
        let pinnedRelay: URL
        /// The confirmation placeholder's key ("confirm" et al), nil when the
        /// operator prefilled it and nothing needs input.
        let confirmKey: String?
    }

    /// Keys whose placeholder a one-tap "approved" may legitimately fill.
    private static let confirmationKeys: Set<String> = [
        "confirm", "confirmation", "ack", "approve",
    ]

    /// Substrings that mark a field as a real secret or identifier a tap can
    /// never supply — presence of any such input field disqualifies the DM.
    private static let secretMarkers = [
        "key", "secret", "token", "pass", "uri", "host", "npub",
    ]

    /// Decide whether a DM is a one-tap-approvable npub-proof challenge.
    ///
    /// Requirements (all): parses as a courier payload; carries a non-empty
    /// dpop_token and a ws/wss rendezvous relay; and its unfilled fields are
    /// at most one confirmation-style placeholder. Credential-channel DMs
    /// (api_key…) and operators whose proof field is a real passphrase
    /// (e.g. taxsort) deliberately fail — a watch tap cannot supply a
    /// meaningful secret, only an affirmation.
    static func classify(_ content: String) -> ProofChallenge? {
        guard let payload = CourierPayload.parse(content) else { return nil }

        guard let token = payload.poison?.value, !token.isEmpty else { return nil }

        guard let relayText = payload.rendezvousRelay?.value,
              let relay = URL(string: relayText),
              let scheme = relay.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss" else { return nil }

        let inputFields = payload.fields.filter {
            $0.needsInput && $0.key.lowercased() != "cache_duration"
        }
        guard inputFields.count <= 1 else { return nil }

        for field in inputFields {
            let key = field.key.lowercased()
            guard confirmationKeys.contains(key) else { return nil }
            guard !secretMarkers.contains(where: key.contains) else { return nil }
        }

        return ProofChallenge(
            payload: payload,
            dpopToken: token,
            pinnedRelay: relay,
            confirmKey: inputFields.first?.key
        )
    }

    // MARK: - Reply Builder

    /// The reply the Approve button sends: affirmation wording plus the
    /// re-serialized form. The operator's parser matches solely on the echoed
    /// dpop_token; `cache_duration` sets how long the proof stays cached.
    static func buildApprovalReply(_ challenge: ProofChallenge, duration: String = defaultDuration) -> String {
        var payload = challenge.payload
        payload.fields = payload.fields.map { field in
            var field = field
            if field.key == challenge.confirmKey {
                field.value = "approved"
            } else if field.key.lowercased() == "cache_duration" {
                field.value = duration
            }
            return field
        }
        if !payload.fields.contains(where: { $0.key.lowercased() == "cache_duration" }) {
            payload.fields.append(CourierPayload.Field(key: "cache_duration", value: duration))
        }
        return "Approved.\n\n\(payload.serialize())"
    }

    // MARK: - userInfo Codec

    /// Everything the notification-action handler needs, captured at post
    /// time so the handler never reloads conversations or re-parses DMs.
    /// The reply content embeds the one-time dpop_token; local-notification
    /// userInfo never leaves the device/watch pairing.
    struct ApprovalRequest: Equatable {
        let signerNpub: String
        let replyToHex: String
        let pinnedRelay: URL
        let replyContent: String
        let eventId: String

        private enum Key {
            static let version = "proofApproval.v"
            static let signerNpub = "proofApproval.signerNpub"
            static let replyToHex = "proofApproval.replyToHex"
            static let pinnedRelay = "proofApproval.pinnedRelay"
            static let replyContent = "proofApproval.replyContent"
            static let eventId = "proofApproval.eventId"
        }

        var userInfo: [String: Any] {
            [
                Key.version: 1,
                Key.signerNpub: signerNpub,
                Key.replyToHex: replyToHex,
                Key.pinnedRelay: pinnedRelay.absoluteString,
                Key.replyContent: replyContent,
                Key.eventId: eventId,
            ]
        }

        init(signerNpub: String, replyToHex: String, pinnedRelay: URL, replyContent: String, eventId: String) {
            self.signerNpub = signerNpub
            self.replyToHex = replyToHex
            self.pinnedRelay = pinnedRelay
            self.replyContent = replyContent
            self.eventId = eventId
        }

        init?(userInfo: [AnyHashable: Any]) {
            guard (userInfo[Key.version] as? Int) == 1,
                  let signerNpub = userInfo[Key.signerNpub] as? String,
                  let replyToHex = userInfo[Key.replyToHex] as? String,
                  let relayText = userInfo[Key.pinnedRelay] as? String,
                  let pinnedRelay = URL(string: relayText),
                  let replyContent = userInfo[Key.replyContent] as? String,
                  let eventId = userInfo[Key.eventId] as? String else { return nil }
            self.signerNpub = signerNpub
            self.replyToHex = replyToHex
            self.pinnedRelay = pinnedRelay
            self.replyContent = replyContent
            self.eventId = eventId
        }
    }

    // MARK: - Notification Category

    /// Approve/Reject actions on the challenge banner. Both actions run in
    /// the background — no `.foreground` and no `.authenticationRequired`,
    /// which would force an iPhone unlock and defeat approving from the
    /// locked phone's mirrored watch notification.
    static func makeCategory() -> UNNotificationCategory {
        let approve = UNNotificationAction(
            identifier: approveActionId,
            title: "Approve · 2 hours",
            options: []
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
