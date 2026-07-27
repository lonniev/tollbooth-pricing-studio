// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DPYCAuthKit",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14),
    ],
    products: [
        .library(name: "DPYCAuthKit", targets: ["DPYCAuthKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/GigaBitcoin/secp256k1.swift.git", exact: "0.23.2"),
    ],
    targets: [
        .target(
            name: "DPYCAuthKit",
            dependencies: [
                .product(name: "P256K", package: "secp256k1.swift"),
            ]
        ),
        .testTarget(
            name: "DPYCAuthKitTests",
            dependencies: ["DPYCAuthKit"]
        ),
    ]
)
