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
        .library(name: "PurseHeadlessCheckout", targets: ["PurseHeadlessCheckout"]),
        // A separate product so a card-only merchant links no PassKit and declares no Apple Pay
        // entitlement — SDK-12264's "un marchand carte-seule n'embarque pas …". Static, for the
        // reason above: an app takes this *and* the core product.
        .library(name: "PurseCheckoutApplePay", targets: ["PurseCheckoutApplePay"]),
        // Same reasoning: a merchant who doesn't offer PayPal never links PayPal's SDK.
        .library(name: "PurseCheckoutPayPal", targets: ["PurseCheckoutPayPal"])
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
        .package(url: "https://github.com/UpStreamPay/purse-securefields-ios.git", from: "1.9.0"),
        // Public repo, real tagged releases. Verified: `swift package resolve` against this URL
        // succeeds and pulls in the PayPalCheckout binary target transitively.
        .package(url: "https://github.com/paypal/paypal-ios.git", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "PurseHeadlessCheckout",
            dependencies: [
                .product(name: "PurseSecureFields", package: "purse-securefields-ios")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "PurseCheckoutApplePay",
            dependencies: ["PurseHeadlessCheckout"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "PurseCheckoutPayPal",
            dependencies: [
                "PurseHeadlessCheckout",
                .product(name: "CorePayments", package: "paypal-ios"),
                .product(name: "PayPalWebPayments", package: "paypal-ios"),
                .product(name: "PaymentButtons", package: "paypal-ios")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PurseHeadlessCheckoutTests",
            dependencies: ["PurseHeadlessCheckout", "PurseCheckoutApplePay", "PurseCheckoutPayPal"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
