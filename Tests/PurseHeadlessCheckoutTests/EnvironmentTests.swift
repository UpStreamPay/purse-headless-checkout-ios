import Foundation
import Testing
@testable import PurseHeadlessCheckout

struct EnvironmentTests {

    @Test(arguments: PurseEnvironment.allCases)
    func everyTierDerivesItsRootsFromOneHost(_ environment: PurseEnvironment) {
        // Each root is the payment root's host plus a suffix; if the derivation breaks, telemetry
        // and clock sync quietly point at the wrong tier rather than failing loudly.
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
