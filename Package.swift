// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PurseHeadlessCheckout",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        // Not `type: .dynamic`. Every optional partner product added higher in this stack depends
        // on this target, and a dynamic product whose name matches its target cannot be linked both
        // directly and transitively by one app: Xcode refuses with "linked as a static library by …
        // but cannot be built dynamically because there is a package product with the same name".
        // So no app could take this product *and* a partner one, which is what splitting them was
        // for. Static costs nothing here — no framework to embed, and the Secure Fields binary
        // target is embedded on its own — and is SPM's default.
        .library(name: "PurseHeadlessCheckout", targets: ["PurseHeadlessCheckout"])
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
