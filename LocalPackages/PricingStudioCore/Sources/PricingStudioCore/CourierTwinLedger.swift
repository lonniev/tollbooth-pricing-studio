import Foundation

/// Counts each courier request once toward unread and banners.
///
/// The courier sends every request twice, as a form and as a text copy, and
/// the two arrive as separate events. A request is one message: the first
/// copy to be announced counts, the other is silent. A text copy waits
/// `textCopyHold` before it is announced, so its form, which usually lands
/// within a second, is the copy that counts.
public struct CourierTwinLedger: Sendable {
    /// How long a text copy waits for its form before it is announced.
    public static let textCopyHold: Duration = .seconds(5)

    private var counted: Set<String> = []

    public init() {}

    /// Whether a message with this request nonce counts. A message that is no
    /// courier request (nil) always counts.
    public mutating func counts(nonce: String?) -> Bool {
        guard let nonce else { return true }
        return counted.insert(nonce).inserted
    }

    /// The ids of *messages* that count, forms before text copies, so a batch
    /// holding both copies counts the form.
    public mutating func countedIds(
        _ messages: [(id: String, formNonce: String?, textNonce: String?)]
    ) -> Set<String> {
        let ordered = messages.filter { $0.formNonce != nil } + messages.filter { $0.formNonce == nil }
        var ids: Set<String> = []
        for m in ordered where counts(nonce: m.formNonce ?? m.textNonce) {
            ids.insert(m.id)
        }
        return ids
    }
}
