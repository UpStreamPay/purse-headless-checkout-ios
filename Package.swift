// swift-tools-version: 6.0

import PackageDescription

// Secure Fields is pinned to a **revision**, not a version range, and deliberately so.
//
// Every tag of purse-securefields-ios is a rewritten manifest whose `.binaryTarget` points at a
// GitHub release asset. That URL returns 404 to SwiftPM for a private repository under every auth
// method SwiftPM supports (verified unauthenticated, and with HTTP basic auth as `--netrc-file`
// sends; only the REST assets endpoint with `Accept: application/octet-stream` succeeds, and
// SwiftPM does not use it). So no tag of that package can currently be resolved by anyone.
//
// `5df309a` is the commit v1.8.0 was cut from — the source tree, before the release workflow
// rewrote the manifest into a binary target. It resolves and builds from source, and it is the
// exact code v1.8.0 ships.
//
// Replace this with `from: "1.8.0"` the moment the distribution issue is fixed; see the README.
let secureFieldsRevision = "5df309aa517b2fc2fa9d0b9c56ebba5a54b7345a"

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
    dependencies: [
        .package(
            url: "git@github.com:UpStreamPay/purse-securefields-ios.git",
            revision: secureFieldsRevision
        )
    ],
    targets: [
        .target(
            name: "PurseHeadlessCheckout",
            dependencies: [
                .product(name: "PurseSecureFields", package: "purse-securefields-ios")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PurseHeadlessCheckoutTests",
            dependencies: ["PurseHeadlessCheckout"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
