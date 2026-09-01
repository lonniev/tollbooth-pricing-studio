import Foundation

/// Pure reconciliation rule for the operator onboarding gate (issue #149).
///
/// The checklist and the screen state both read the same server onboarding
/// truth, but they are owned separately in the app:
/// - screen state is decided once during `startLoading` / `retry`
/// - checklist content is refreshed by `loadOnboardingStatus` (Check / `.task`)
///
/// When a refresh shows `ready == true` while the screen is still gated on
/// "registered but needs configuration", the gate must lift. Without this,
/// Check greens every checklist row under a headline that still says
/// "needs configuration".
public enum OnboardingGateLift {
    /// Whether a fresh onboarding status should lift the configuration gate.
    ///
    /// - Parameters:
    ///   - statusReady: `OnboardingStatus.ready` from the latest fetch.
    ///   - isRegisteredNotConfigured: whether the screen is currently gated
    ///     on the "registered but needs configuration" state.
    public static func shouldLift(
        statusReady: Bool,
        isRegisteredNotConfigured: Bool
    ) -> Bool {
        statusReady && isRegisteredNotConfigured
    }
}
