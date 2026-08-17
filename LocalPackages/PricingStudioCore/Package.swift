// swift-tools-version: 6.0
import PackageDescription

// PricingStudioCore — host-free pure-logic extracted from the app so its tests
// run in CI via `swift test` (no simulator, no app launch). Slices:
// Secure-Courier DM parsing (CourierPayload), npub-proof approval classification
// (ProofApprovalService), proof provenance, notification prefs, the Courier
// Bridge wake doctrine (CourierBridgeDoctrine), and content-free wake
// recognition + device-token registration shape (CourierBridgeWake). Mirrors
// the DPYCAuthKit local-package pattern.
let package = Package(
    name: "PricingStudioCore",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14),
    ],
    products: [
        .library(name: "PricingStudioCore", targets: ["PricingStudioCore"]),
    ],
    targets: [
        .target(name: "PricingStudioCore"),
        .testTarget(
            name: "PricingStudioCoreTests",
            dependencies: ["PricingStudioCore"]
        ),
    ]
)
