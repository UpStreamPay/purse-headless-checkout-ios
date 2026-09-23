import Foundation
import Testing
@testable import PurseHeadlessCheckout

struct EnvironmentTests {

    @Test(arguments: PurseEnvironment.allCases)
    func everyTierDerivesItsRootsFromOneHost(_ environment: PurseEnvironment) {
        // A broken derivation points telemetry and clock sync at the wrong tier, silently.
        let host = environment.paymentAPIRoot.replacingOccurrences(of: "/payment/v1", with: "")
        #expect(environment.datetimeAPIRoot == host + "/datetime")
        #expect(environment.walletAPIRoot == host + "/wallet/v2")
        #expect(environment.monitoringAPIRoot == host + "/widget/headless_checkout")
    }

    @Test func everyRootIsHTTPS() {
        for environment in PurseEnvironment.allCases {
            #expect(environment.paymentAPIRoot.hasPrefix("https://"))
        }
    }

    @Test func productionPointsAtTheLiveHost() {
        #expect(PurseEnvironment.production.paymentAPIRoot == "https://api.purse-live.com/payment/v1")
    }

    @Test func fromWireRejectsTheUnknown() {
        #expect(PurseEnvironment.fromWire("sandbox") == .sandbox)
        #expect(PurseEnvironment.fromWire("staging") == nil)
        #expect(PurseEnvironment.fromWire(nil) == nil)
    }
}

/// The internal tiers never reach an App Store build — Secure Fields' `VaultEnvironment.resolve`.
struct EnvironmentGateTests {

    @Test(arguments: PurseEnvironment.allCases)
    func aDevelopmentBuildGetsWhatItAsked(_ environment: PurseEnvironment) {
        #expect(PurseEnvironment.resolve(environment, isDebugHost: true) == environment)
    }

    @Test func aReleaseBuildFallsBackToProductionFromTheInternalTiers() {
        #expect(PurseEnvironment.resolve(.test, isDebugHost: false) == .production)
        #expect(PurseEnvironment.resolve(.development, isDebugHost: false) == .production)
        #expect(PurseEnvironment.resolve(.sandbox, isDebugHost: false) == .sandbox)
        #expect(PurseEnvironment.resolve(.production, isDebugHost: false) == .production)
    }
}
