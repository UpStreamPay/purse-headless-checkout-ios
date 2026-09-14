// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PurseHeadlessCheckout",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(name: "PurseHeadlessCheckout", type: .dynamic, targets: ["PurseHeadlessCheckout"])
    ],
    targets: [
        .target(
            name: "PurseHeadlessCheckout",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PurseHeadlessCheckoutTests",
            dependencies: ["PurseHeadlessCheckout"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
