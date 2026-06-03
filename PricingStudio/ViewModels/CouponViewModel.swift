import Foundation
import SwiftUI

/// Operator-side coupon CRUD viewmodel.
///
/// Caches the operator's coupon list and exposes mint / update / delete
/// over MCPService.  Owned by ``OperatorAuthorityView`` (or equivalent)
/// and passed down to ``CouponsView`` + ``ConstraintParamEditor`` so
/// they all share the same in-memory list.
@MainActor
@Observable
final class CouponViewModel {

    enum LoadState: Sendable {
        case idle
        case loading
        case loaded
        case error(String)
    }

    private(set) var loadState: LoadState = .idle
    private(set) var coupons: [Coupon] = []
    private(set) var lastFetchedAt: Date?

    /// Inline feedback shown in the mint sheet / row editor.
    var inlineMessage: String?

    private let mcpService: MCPService
    private var pendingLoad: Task<Void, Never>?

    init(mcpService: MCPService = MCPService()) {
        self.mcpService = mcpService
    }

    // MARK: - Refresh

    func refresh(endpointURL: URL, operatorNpub: String) {
        pendingLoad?.cancel()
        loadState = .loading
        pendingLoad = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await mcpService.callListCoupons(
                    endpointURL: endpointURL, operatorNpub: operatorNpub,
                )
                if Task.isCancelled { return }
                coupons = result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                lastFetchedAt = .now
                loadState = .loaded
            } catch {
                if Task.isCancelled { return }
                loadState = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Mutations

    @discardableResult
    func mint(
        endpointURL: URL,
        operatorNpub: String,
        name: String,
        discountPercent: Double,
        validFrom: Date,
        validUntil: Date,
        usesPerPatron: Int?,
        totalUses: Int?,
    ) async throws -> Coupon {
        let coupon = try await mcpService.callMintCoupon(
            endpointURL: endpointURL,
            operatorNpub: operatorNpub,
            name: name,
            discountPercent: discountPercent,
            validFrom: validFrom,
            validUntil: validUntil,
            usesPerPatron: usesPerPatron,
            totalUses: totalUses,
        )
        coupons.append(coupon)
        coupons.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return coupon
    }

    @discardableResult
    func update(
        endpointURL: URL,
        operatorNpub: String,
        couponId: String,
        name: String? = nil,
        discountPercent: Double? = nil,
        validFrom: Date? = nil,
        validUntil: Date? = nil,
        usesPerPatron: Int? = nil,
        totalUses: Int? = nil,
        clearUsesPerPatron: Bool = false,
        clearTotalUses: Bool = false,
    ) async throws -> Coupon {
        let updated = try await mcpService.callUpdateCoupon(
            endpointURL: endpointURL,
            operatorNpub: operatorNpub,
            couponId: couponId,
            name: name,
            discountPercent: discountPercent,
            validFrom: validFrom,
            validUntil: validUntil,
            usesPerPatron: usesPerPatron,
            totalUses: totalUses,
            clearUsesPerPatron: clearUsesPerPatron,
            clearTotalUses: clearTotalUses,
        )
        if let idx = coupons.firstIndex(where: { $0.id == couponId }) {
            coupons[idx] = updated
        } else {
            coupons.append(updated)
        }
        return updated
    }

    func delete(
        endpointURL: URL,
        operatorNpub: String,
        couponId: String,
    ) async throws {
        try await mcpService.callDeleteCoupon(
            endpointURL: endpointURL,
            operatorNpub: operatorNpub,
            couponId: couponId,
        )
        coupons.removeAll { $0.id == couponId }
    }

    // MARK: - Lookups

    func coupon(withId id: String) -> Coupon? {
        coupons.first(where: { $0.id == id })
    }

    /// Used by ``ConstraintParamEditor``'s coupon picker —
    /// only show coupons that are usable (not expired, not fully claimed).
    var pickableCoupons: [Coupon] {
        coupons.filter { $0.status() == .active || $0.status() == .notYetActive }
    }
}
