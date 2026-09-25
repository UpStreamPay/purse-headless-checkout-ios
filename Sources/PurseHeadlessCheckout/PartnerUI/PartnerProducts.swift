// Web: none — web bundles every plugin.
// Same: Android's `PartnerArtifacts`: which optional product provides a method's plugin.
// Differs: SPM product names; Apple Pay in place of Google Pay.

import Foundation

/// The optional SPM product a method's plugin ships in, so a missing one can be named.
enum PartnerProducts {

    static func product(partner: Partner, method: PaymentMethod) -> String? {
        switch (partner, method) {
        case (_, .applePay): "PurseCheckoutApplePay"
        case (.klarna, .installments): "PurseCheckoutKlarna"
        case (.paypal, .wallet): "PurseCheckoutPayPal"
        default: nil
        }
    }
}
