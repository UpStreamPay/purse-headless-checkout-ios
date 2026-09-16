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
    dependencies: [
        // **https, not ssh.** `git@github.com:` authenticates regardless of repository
        // visibility, so an SSH URL needs a key the CI runner does not have — that, not the
        // repository being private, is what failed every job from the card-payment layer up.
        //
        // A real version range at last. The long-standing workaround (a pinned revision, because
        // every tag rewrites the manifest into a `.binaryTarget` whose release asset 404'd for a
        // private repo) is gone now the repository is public: the assets answer 200
        // unauthenticated, and the xcframework resolves, links and passes the suite.
        //
        // One trap worth recording, since it cost a wrong diagnosis: switching between the source
        // pin and the binary artifact leaves a stale `PurseSecureFields.framework` in DerivedData,
        // and the mismatch surfaces as `Undefined symbol:
        // PurseSecureFields.SecureFieldsStyle.default.unsafeMutableAddressor` — which reads exactly
        // like a broken release. Wipe DerivedData before concluding anything about an artifact.
        .package(url: "https://github.com/UpStreamPay/purse-securefields-ios.git", from: "1.9.0")
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
