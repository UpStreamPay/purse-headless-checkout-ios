# Changelog

## [1.2.0](https://github.com/UpStreamPay/purse-headless-checkout-ios/compare/v1.1.0...v1.2.0) (2026-10-02)


### Features

* plugin events, amount updates, compatibility probe and API call timing ([#32](https://github.com/UpStreamPay/purse-headless-checkout-ios/issues/32)) ([260c3d3](https://github.com/UpStreamPay/purse-headless-checkout-ios/commit/260c3d3d374a7ddd4241a836c6da25a04cdfdf40))


### Documentation

* **contributing:** CI gates, release approval and the repository settings (SDK-12355) ([f6e18ab](https://github.com/UpStreamPay/purse-headless-checkout-ios/commit/f6e18abf3d22268f3f1c15cd2a0b15afe74e582f))
* **contributing:** why release-please and release are two environments (SDK-12355) ([fc20ddf](https://github.com/UpStreamPay/purse-headless-checkout-ios/commit/fc20ddf5cb8c9cb240b3c993de916df27bb523a5))

## [1.1.0](https://github.com/UpStreamPay/purse-headless-checkout-ios/compare/v1.0.0...v1.1.0) (2026-09-23)


### Features

* **card:** co-badge selector, relayed field state, stable field identifiers ([#24](https://github.com/UpStreamPay/purse-headless-checkout-ios/issues/24)) ([961c99f](https://github.com/UpStreamPay/purse-headless-checkout-ios/commit/961c99f640506c1e09cd7fb7e0a63ac1f036c5ec))
* ship signed XCFrameworks on every release, like Secure Fields ([#29](https://github.com/UpStreamPay/purse-headless-checkout-ios/issues/29)) ([7b535ee](https://github.com/UpStreamPay/purse-headless-checkout-ios/commit/7b535ee418ffcb09155b09a556942142ac2562d3))


### Documentation

* lockedEnvironment ignores api_url, InitGuard retry policy, actionable card validation error ([#26](https://github.com/UpStreamPay/purse-headless-checkout-ios/issues/26)) ([c68c832](https://github.com/UpStreamPay/purse-headless-checkout-ios/commit/c68c83230b5cfe02ca4878f22e3988cdd6bf5fbe))

## 1.0.0 (2026-09-18)


### Features

* Apple Pay ([#8](https://github.com/UpStreamPay/purse-headless-checkout-ios/issues/8)) ([8b0517b](https://github.com/UpStreamPay/purse-headless-checkout-ios/commit/8b0517bfa727394dd88feec5c1260f946143a2bb))
* card payment through Secure Fields ([#4](https://github.com/UpStreamPay/purse-headless-checkout-ios/issues/4)) ([a13342c](https://github.com/UpStreamPay/purse-headless-checkout-ios/commit/a13342c205e06bea280948ca54b1538cdfbd3dda))
* gift cards, vouchers and loyalty as secondary payment methods ([c4e5773](https://github.com/UpStreamPay/purse-headless-checkout-ios/commit/c4e577385bac539937bb4174dd87c980398c1ade))
* Klarna installments ([#10](https://github.com/UpStreamPay/purse-headless-checkout-ios/issues/10)) ([f04455b](https://github.com/UpStreamPay/purse-headless-checkout-ios/commit/f04455b2fbb4a6c53bc7bb92581b4b7b1a7ae947))
* observability - event bus, monitoring collector, privacy tests (SDK-12265) ([#15](https://github.com/UpStreamPay/purse-headless-checkout-ios/issues/15)) ([632025a](https://github.com/UpStreamPay/purse-headless-checkout-ios/commit/632025ac567c043d4ccd195df2ad51fddaa8de9d))
* payment confirmation, method badges, and a shopper-facing demo ([#22](https://github.com/UpStreamPay/purse-headless-checkout-ios/issues/22)) ([a4c5d42](https://github.com/UpStreamPay/purse-headless-checkout-ios/commit/a4c5d42c6bcabdd49a4f81114a95b1426b199380))
* payment elements — one shape for every method, whatever it renders ([#19](https://github.com/UpStreamPay/purse-headless-checkout-ios/issues/19)) ([bb5ce4f](https://github.com/UpStreamPay/purse-headless-checkout-ios/commit/bb5ce4f34fe5c616b1403604066f6588572d0a86))
* payment model, splitter and reactive checkout state ([#2](https://github.com/UpStreamPay/purse-headless-checkout-ios/issues/2)) ([1ec7875](https://github.com/UpStreamPay/purse-headless-checkout-ios/commit/1ec7875089e78329ecfce747d1390a21ffd66586))
* PayPal wallet ([#9](https://github.com/UpStreamPay/purse-headless-checkout-ios/issues/9)) ([8c9832f](https://github.com/UpStreamPay/purse-headless-checkout-ios/commit/8c9832ff3026e0a10584ebac2981bd661fedc89b))
* plugin contract, registry, redirect resolution and the validate pipeline ([#3](https://github.com/UpStreamPay/purse-headless-checkout-ios/issues/3)) ([306befd](https://github.com/UpStreamPay/purse-headless-checkout-ios/commit/306befdadbc7124a69df4cba87edefad11dde6f8))
* present redirects, with an allowlist ([#6](https://github.com/UpStreamPay/purse-headless-checkout-ios/issues/6)) ([ea65e53](https://github.com/UpStreamPay/purse-headless-checkout-ios/commit/ea65e538c926e90ae31a81f51e14bfbc55aeb164))
* PrivacyInfo.xcprivacy (SDK-12264, partial) ([ad564bc](https://github.com/UpStreamPay/purse-headless-checkout-ios/commit/ad564bc9707fe4e48458630dbfa759ffd871a3ac))
* PurseHeadlessCheckout.host(for:) — the concrete PluginHost ([#17](https://github.com/UpStreamPay/purse-headless-checkout-ios/issues/17)) ([1a389ea](https://github.com/UpStreamPay/purse-headless-checkout-ios/commit/1a389ea867b74e539fb28ea6f7a3670ce84d8d1e))
* repo skeleton and Core layer ([#1](https://github.com/UpStreamPay/purse-headless-checkout-ios/issues/1)) ([e77c910](https://github.com/UpStreamPay/purse-headless-checkout-ios/commit/e77c9102b31148645498a5c65a5902b03b3d6aa1))
* saved gift card background balance resolution ([#11](https://github.com/UpStreamPay/purse-headless-checkout-ios/issues/11)) ([f9534e7](https://github.com/UpStreamPay/purse-headless-checkout-ios/commit/f9534e759e47037c0e3254558a3ecb008980af88))
* saved methods, save-at-submit, BNPL loan simulation, theming (SDK-12262) ([#13](https://github.com/UpStreamPay/purse-headless-checkout-ios/issues/13)) ([63c1e32](https://github.com/UpStreamPay/purse-headless-checkout-ios/commit/63c1e32dc742d9a83bf18b206c0b079034366a32))
* teardown, process-death state restoration, error-code coverage (SDK-12263 remainder) ([#14](https://github.com/UpStreamPay/purse-headless-checkout-ios/issues/14)) ([abe3137](https://github.com/UpStreamPay/purse-headless-checkout-ios/commit/abe3137698f8aa6f262ef5bd498aa342316e1337))
* the Demo is a three-screen tour of every method, on real sessions ([#18](https://github.com/UpStreamPay/purse-headless-checkout-ios/issues/18)) ([cce4fa8](https://github.com/UpStreamPay/purse-headless-checkout-ios/commit/cce4fa88eec45a6dc71a84ea8693ea98bd1bf09f))


### Bug Fixes

* the SDK reported 0.0.0-SNAPSHOT on every monitoring event ([#23](https://github.com/UpStreamPay/purse-headless-checkout-ios/issues/23)) ([70da03e](https://github.com/UpStreamPay/purse-headless-checkout-ios/commit/70da03e11940d6227346e4953de456f2ddad111f))


### Documentation

* payment methods matrix ([#12](https://github.com/UpStreamPay/purse-headless-checkout-ios/issues/12)) ([4143e7c](https://github.com/UpStreamPay/purse-headless-checkout-ios/commit/4143e7c085dc2e2fada74558868717d577e37e1a))
