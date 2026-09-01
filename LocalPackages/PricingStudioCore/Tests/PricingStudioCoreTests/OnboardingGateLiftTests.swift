import XCTest
@testable import PricingStudioCore

/// Pins the reconciliation rule for issue #149: when onboarding status
/// becomes ready while the detail screen is still gated on
/// "registered but needs configuration", the gate must lift. Without this,
/// Check refreshes the checklist but never the screen state, so the UI
/// contradicts itself — green rows under "needs configuration".
final class OnboardingGateLiftTests: XCTestCase {

    /// Ready + gated → lift. The field-confirmed path: credentials land,
    /// Check re-fetches, status.ready flips true while the screen is still
    /// on the configuration gate.
    func testLiftsWhenReadyAndGated() {
        XCTAssertTrue(
            OnboardingGateLift.shouldLift(
                statusReady: true,
                isRegisteredNotConfigured: true
            )
        )
    }

    /// Not ready + gated → stay. Genuinely incomplete operators keep the gate.
    func testDoesNotLiftWhenNotReadyAndGated() {
        XCTAssertFalse(
            OnboardingGateLift.shouldLift(
                statusReady: false,
                isRegisteredNotConfigured: true
            )
        )
    }

    /// Ready but already past the gate → no-op. Avoids re-entering load
    /// from a checklist refresh on the loaded pricing editor.
    func testDoesNotLiftWhenAlreadyPastGate() {
        XCTAssertFalse(
            OnboardingGateLift.shouldLift(
                statusReady: true,
                isRegisteredNotConfigured: false
            )
        )
    }

    /// Not ready and not gated → never lift.
    func testDoesNotLiftWhenNotReadyAndNotGated() {
        XCTAssertFalse(
            OnboardingGateLift.shouldLift(
                statusReady: false,
                isRegisteredNotConfigured: false
            )
        )
    }
}
