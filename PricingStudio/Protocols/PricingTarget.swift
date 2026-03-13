import Foundation

/// A common interface for entities whose pricing model can be viewed.
/// Both `Operator` and `Authority` conform.
protocol PricingTarget: AnyObject {
    var npub: String { get }
    var displayName: String { get }
    var mcpEndpointURL: String? { get set }
}
