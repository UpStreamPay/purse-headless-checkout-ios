import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// Badge URL resolution: pure string builders, where a wrong path 404s silently in a merchant's UI.
@Suite
struct PurseAssetsTests {

    @Test func productionUsesTheSecureCdnAndEveryOtherTierTheSandboxOne() {
        #expect(PurseAssets.cdnBase(.production) == "https://cdn.purse-secure.com/assets/")
        for environment in [PurseEnvironment.development, .test, .sandbox] {
            #expect(PurseAssets.cdnBase(environment) == "https://cdn.purse-sandbox.com/assets/")
        }
    }

    @Test func aBadgeUrlIsTheCdnBasePlusThePath() {
        #expect(
            PurseAssets.badgeURL(.production, badgeName: "visa")
                == "https://cdn.purse-secure.com/assets/img/badges/visa.svg"
        )
    }

    /// Adyen fronts cards, Apple Pay and Google Pay, so the method decides the badge.
    @Test func aPerMethodOverrideWinsOverThePartnerDefault() {
        let applePay = PurseAssets.resolveIconURL(
            partner: .adyen, method: .applePay, isSecondary: false, environment: .sandbox
        )
        let card = PurseAssets.resolveIconURL(
            partner: .adyen, method: .creditCard, isSecondary: false, environment: .sandbox
        )
        #expect(applePay.hasSuffix("/applepay.svg"))
        #expect(card.hasSuffix("/creditcard.svg"))
    }

    @Test func aPartnerWithOnlyADefaultUsesItForEveryMethod() {
        for method in [PaymentMethod.installments, .creditCard, .other("whatever")] {
            let url = PurseAssets.resolveIconURL(
                partner: .klarna, method: method, isSecondary: false, environment: .sandbox
            )
            #expect(url.hasSuffix("/klarna.svg"))
        }
    }

    /// An unknown partner is the common case for a new PSP, and must still render something.
    @Test func anUnknownPartnerFallsBackByPrimaryOrSecondary() {
        let primary = PurseAssets.resolveIconURL(
            partner: .other("brand-new-psp"), method: .creditCard, isSecondary: false, environment: .sandbox
        )
        let secondary = PurseAssets.resolveIconURL(
            partner: .other("brand-new-psp"), method: .giftCard, isSecondary: true, environment: .sandbox
        )
        #expect(primary.hasSuffix("/creditcard.svg"))
        #expect(secondary.hasSuffix("/giftcard2.svg"))
    }

    /// A known partner's own default wins over the secondary fallback.
    @Test func aKnownSecondaryPartnerUsesItsOwnBadges() {
        let voucher = PurseAssets.resolveIconURL(
            partner: .other("easy2play"), method: .other("voucher"), isSecondary: true, environment: .sandbox
        )
        let giftCard = PurseAssets.resolveIconURL(
            partner: .other("easy2play"), method: .giftCard, isSecondary: true, environment: .sandbox
        )
        #expect(voucher.hasSuffix("/voucher.svg"))
        #expect(giftCard.hasSuffix("/giftcard2.svg"))
    }

    @Test func schemeAssetsCarryABadgeAndALabelPerBrand() {
        let assets = PurseAssets.buildCardSchemeAssets(
            brands: [.visa, .americanExpress, .carteBancaire], environment: .production
        )
        #expect(assets.map(\.label) == ["Visa", "American Express", "Cartes Bancaires"])
        #expect(assets.first?.url == "https://cdn.purse-secure.com/assets/img/badges/visa.svg")
        // Not the wire value: the Payment API says AMERICAN_EXPRESS, the badge file is amex.svg.
        #expect(assets[1].url.hasSuffix("/amex.svg"))
    }

    /// A brand with no badge is dropped, not pointed at a URL that would 404.
    @Test func brandsWithoutABadgeAreLeftOut() {
        let assets = PurseAssets.buildCardSchemeAssets(
            brands: [.visa, .jcb, .unionPay, .dinersClub, .discover, .unknown], environment: .sandbox
        )
        #expect(assets.count == 1)
        #expect(assets.first?.label == "Visa")
    }

    @Test func noBrandsMeansNoAssets() {
        #expect(PurseAssets.buildCardSchemeAssets(brands: [], environment: .sandbox).isEmpty)
    }
}
