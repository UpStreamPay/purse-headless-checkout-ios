import Foundation
import Testing
@testable import PurseHeadlessCheckout

@MainActor
struct PaymentSessionBuilderTests {

    private func build(
        amount: Any? = 100,
        protocols: [String: Any] = TestSessions.cardProtocol(),
        informationRequest: Bool? = nil,
        disabledMethods: Set<MethodKey> = []
    ) throws -> PaymentSession {
        var extra: [String: Any] = [:]
        if let informationRequest { extra["information_request"] = informationRequest }
        let session = TestSessions.paymentSession(amount: amount, protocols: protocols, extra: extra)
        let params = try SessionCodec.decode(TestSessions.widgetData(paymentSession: session))
        return PaymentSessionBuilder.build(params.paymentSession, disabledMethods: disabledMethods)
    }

    @Test func buildsAPrimaryMethodFromProtocols() throws {
        let built = try build()
        #expect(built.meansOfPayment.count == 1)

        guard case let .primaryMethod(card) = built.meansOfPayment[0] else {
            Issue.record("expected a primary method")
            return
        }
        #expect(card.id == "purse-creditcard")
        #expect(card.supportedBrands == [.visa, .mastercard])
        #expect(card.disabled == nil)
    }

    @Test func carriesTheAmountInBothUnits() throws {
        let built = try build(amount: 42.50)
        #expect(built.amount == Decimal(string: "42.50"))
        #expect(built.amountCents == 4250)
    }

    /// A method carrying the `secondary` label becomes a secondary item, not a primary.
    @Test func labelsDecidePrimaryVersusSecondary() throws {
        let built = try build(protocols: TestSessions.cardProtocol(labels: ["secondary"]))
        guard case .secondaryMethod = built.meansOfPayment[0] else {
            Issue.record("expected a secondary method")
            return
        }
    }

    // MARK: Build-time availability

    @Test func anUnstableMethodIsDisabledAndFiltered() throws {
        var protocols = TestSessions.cardProtocol()
        // stable: false is the platform suspending the method.
        var entry = ((protocols["purse"] as! [String: Any])["creditcard"] as! [String: Any])
        var configurations = entry["configurations"] as! [String: Any]
        configurations["stable"] = false
        entry["configurations"] = configurations
        protocols = ["purse": ["creditcard": entry]]

        let built = try build(protocols: protocols)
        #expect(built.meansOfPayment[0].disabled == .methodUnstable)
        #expect(built.meansOfPayment[0].disabled?.isFiltered == true)
    }

    /// A minimum above the whole order can never be met by any split.
    @Test func aMinimumAboveTheOrderIsUnreachable() throws {
        let built = try build(
            amount: 10,
            protocols: TestSessions.cardProtocol(settings: ["payment_min_amount": 50])
        )
        #expect(built.meansOfPayment[0].disabled?.code == .amountConditionUnreachable)
        #expect(built.meansOfPayment[0].disabled?.isFiltered == true)
    }

    @Test func aMaximumBelowTheOrderDisablesOnAmount() throws {
        let built = try build(
            amount: 100,
            protocols: TestSessions.cardProtocol(settings: ["payment_max_amount": 50])
        )
        #expect(built.meansOfPayment[0].disabled?.code == .maxAmountExceeded)
        // Not filtered: covering part of the order with a gift card can bring it back.
        #expect(built.meansOfPayment[0].disabled?.isFiltered == false)
        #expect(built.meansOfPayment[0].disabled?.isRecomputable == true)
    }

    // MARK: Opting out

    @Test func disabledMethodsAreDroppedEntirely() throws {
        let built = try build(disabledMethods: [MethodKey(partner: .purse, method: .creditCard)])
        #expect(built.meansOfPayment.isEmpty)
    }

    // MARK: Information requests

    /// A zero-amount session is an information request even when the flag is absent.
    @Test func zeroAmountImpliesAnInformationRequest() throws {
        #expect(try build(amount: 0).isInformationRequest)
        #expect(try build(amount: nil).isInformationRequest)
        #expect(try !build(amount: 100).isInformationRequest)
    }

    /// Only OFF_SESSION-registrable methods take part in an information request; the rest are
    /// dropped, not merely disabled.
    @Test func informationRequestsKeepOnlyOffSessionMethods() throws {
        let onSession = try build(
            amount: 0,
            protocols: TestSessions.cardProtocol(settings: ["registration_mode": "ON_SESSION"])
        )
        #expect(onSession.meansOfPayment.isEmpty)

        let offSession = try build(
            amount: 0,
            protocols: TestSessions.cardProtocol(settings: ["registration_mode": "OFF_SESSION"])
        )
        #expect(offSession.meansOfPayment.count == 1)
    }

    /// Saved instruments are stripped from an information request — the goal is collecting data,
    /// not paying with a card already on file.
    @Test func informationRequestsCarryNoSavedInstruments() throws {
        let token: [String: Any] = ["id": "tok-1", "value": "v1"]
        let built = try build(
            amount: 0,
            protocols: TestSessions.cardProtocol(
                settings: ["registration_mode": "OFF_SESSION"],
                integratedTokens: [token]
            )
        )
        #expect(built.meansOfPayment.count == 1)
        #expect(built.meansOfPayment.allSatisfy { if case .paymentToken = $0 { false } else { true } })
    }

    // MARK: Saved instruments

    @Test func savedCardsBecomePaymentTokens() throws {
        let token: [String: Any] = ["id": "tok-1", "value": "v1", "description": ["masked_pan": "•••• 1111"]]
        let built = try build(protocols: TestSessions.cardProtocol(integratedTokens: [token]))

        let tokens = built.meansOfPayment.compactMap { item -> PaymentToken? in
            if case let .paymentToken(token) = item { return token }
            return nil
        }
        #expect(tokens.count == 1)
        #expect(tokens[0].maskedPAN == "•••• 1111")
    }

    /// The same row under a *secondary* method is a saved gift card, not a saved card.
    @Test func savedGiftCardsBecomeSavedSecondaryTokens() throws {
        let token: [String: Any] = ["id": "tok-1", "value": "v1", "uniqueness_token": "u1", "pin_code": "1234"]
        let built = try build(
            protocols: TestSessions.cardProtocol(labels: ["secondary"], integratedTokens: [token])
        )

        let saved = built.meansOfPayment.compactMap { item -> SavedSecondaryToken? in
            if case let .savedSecondaryToken(token) = item { return token }
            return nil
        }
        #expect(saved.count == 1)
        #expect(saved[0].pan == "u1")
        #expect(saved[0].cvv == "1234")
        // The session carries no balance; it is resolved later by a background /init.
        #expect(saved[0].balance == 0)
        #expect(!saved[0].balanceResolved)
    }

    // MARK: Ordering

    @Test func itemsSortByPositionWithUnpositionedLast() throws {
        func entry(position: Int?) -> [String: Any] {
            var configurations: [String: Any] = ["stable": true, "labels": [], "settings": [:]]
            if let position { configurations["position"] = position }
            return ["configurations": configurations]
        }
        let protocols: [String: Any] = [
            "aci": ["creditcard": entry(position: nil)],
            "adyen": ["creditcard": entry(position: 2)],
            "paypal": ["wallet": entry(position: 1)],
        ]

        let ids = try build(protocols: protocols).meansOfPayment.map(\.id)
        #expect(ids == ["paypal-wallet", "adyen-creditcard", "aci-creditcard"])
    }
}
