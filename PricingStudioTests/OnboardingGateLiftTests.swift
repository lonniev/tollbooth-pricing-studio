import XCTest
@testable import PricingStudio

/// Pins the reconciliation rule for issue #149: when onboarding status
/// becomes ready while the detail screen is still gated on
/// `.registeredNotConfigured`, the gate must lift. Without this, Check
/// refreshes the checklist (owner 2) but never the screen state (owner 1),
/// so the UI contradicts itself — green rows under "needs configuration".
@MainActor
final class OnboardingGateLiftTests: XCTestCase {

    // MARK: - shouldLiftConfigurationGate

    /// Ready + gated → lift. The field-confirmed path: credentials land,
    /// Check re-fetches, status.ready flips true while state is still
    /// `.registeredNotConfigured`.
    func testLiftsWhenReadyAndGated() {
        XCTAssertTrue(
            PricingViewModel.shouldLiftConfigurationGate(
                statusReady: true,
                screenState: .registeredNotConfigured
            )
        )
    }

    /// Not ready + gated → stay. Genuinely incomplete operators keep the gate.
    func testDoesNotLiftWhenNotReadyAndGated() {
        XCTAssertFalse(
            PricingViewModel.shouldLiftConfigurationGate(
                statusReady: false,
                screenState: .registeredNotConfigured
            )
        )
    }

    /// Ready but already past the gate → no-op. Avoids re-entering
    /// `startLoading` from a checklist refresh on the loaded editor.
    func testDoesNotLiftWhenAlreadyLoaded() {
        let loaded = PricingModelResponse(
            status: "ok",
            modelId: nil,
            name: nil,
            isActive: nil,
            tools: nil,
            trancheLifetime: nil
        )
        XCTAssertFalse(
            PricingViewModel.shouldLiftConfigurationGate(
                statusReady: true,
                screenState: .loaded(loaded)
            )
        )
    }

    /// Ready in other non-gated states → no-op.
    func testDoesNotLiftInOtherStates() {
        let states: [PricingViewModel.State] = [
            .idle,
            .loading(step: "Checking configuration..."),
            .error("boom"),
            .notRegistered,
            .cancelled,
        ]
        for state in states {
            XCTAssertFalse(
                PricingViewModel.shouldLiftConfigurationGate(
                    statusReady: true,
                    screenState: state
                ),
                "should not lift from \(state)"
            )
        }
    }

    /// Not ready in any state → never lift.
    func testNeverLiftsWhenNotReady() {
        let states: [PricingViewModel.State] = [
            .idle,
            .loading(step: "x"),
            .registeredNotConfigured,
            .notRegistered,
            .error("x"),
            .cancelled,
        ]
        for state in states {
            XCTAssertFalse(
                PricingViewModel.shouldLiftConfigurationGate(
                    statusReady: false,
                    screenState: state
                )
            )
        }
    }
}
