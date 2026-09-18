import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// The public reactive surface a merchant binds to.
@MainActor
struct PurseHeadlessCheckoutTests {

    private func checkout(
        amount: Any? = 100,
        protocols: [String: Any] = TestSessions.cardProtocol(),
        disabledMethods: Set<MethodKey> = []
    ) throws -> PurseHeadlessCheckout {
        try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(
                paymentSession: TestSessions.paymentSession(amount: amount, protocols: protocols)
            ),
            disabledMethods: disabledMethods
        )
    }

    private func giftCard(id: String = "gift-1", balance: Decimal) -> SecondaryToken {
        SecondaryToken(
            id: id, partner: .illicado, method: .giftCard,
            pan: "9250004787002023349", cvv: "123", name: "gift", balance: balance
        )
    }

    private func firstPrimary(_ checkout: PurseHeadlessCheckout) throws -> PrimaryMethod {
        let method = checkout.paymentMethods.compactMap { item -> PrimaryMethod? in
            if case let .primaryMethod(method) = item { return method }
            return nil
        }.first
        return try #require(method)
    }

    // MARK: Creation

    @Test func startsReadyWithTheSessionsMethods() throws {
        let checkout = try checkout()

        #expect(checkout.sessionState == .ready)
        #expect(checkout.paymentMethods.count == 1)
        #expect(checkout.remainingAmountToPay == 100)
        #expect(!checkout.isPaymentFulfilled)
        #expect(checkout.currentSessionId == "session-1")
        #expect(checkout.currency == "EUR")
    }

    /// A release build passes a locked environment rather than trusting the session's.
    @Test func aLockedEnvironmentOverridesTheSession() throws {
        let checkout = try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(environment: "sandbox"),
            lockedEnvironment: .production
        )
        #expect(checkout.paymentAPIRoot == PurseEnvironment.production.paymentAPIRoot)
    }

    /// An unlocked build reaches a tenant- or region-specific Payment API host; locking buys the
    /// guarantee that it cannot.
    @Test func anUnlockedBuildRoutesToTheSessionsApiURLAndALockedOneIgnoresIt() throws {
        let tenantHost = "https://api.tenant-42.purse-sandbox.com/payment/v1"

        let unlocked = try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(apiURL: tenantHost)
        )
        #expect(unlocked.paymentAPIRoot == tenantHost)

        let locked = try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(apiURL: tenantHost),
            lockedEnvironment: .production
        )
        #expect(locked.paymentAPIRoot == PurseEnvironment.production.paymentAPIRoot)

        // A blob that omits it falls back to the declared tier's root.
        let noURL = try PurseHeadlessCheckout(widgetData: TestSessions.widgetData(apiURL: ""))
        #expect(noURL.paymentAPIRoot == PurseEnvironment.sandbox.paymentAPIRoot)
    }

    /// A new blob can name a different host, so the root cannot be resolved once at init.
    @Test func setSessionReResolvesTheApiRoot() throws {
        let checkout = try PurseHeadlessCheckout(widgetData: TestSessions.widgetData())
        #expect(checkout.paymentAPIRoot == PurseEnvironment.sandbox.paymentAPIRoot)

        let moved = "https://api.moved.purse-sandbox.com/payment/v1"
        try checkout.setSession(
            TestSessions.widgetData(
                apiURL: moved,
                paymentSession: TestSessions.paymentSession(id: "session-2")
            )
        )
        #expect(checkout.paymentAPIRoot == moved)
    }

    /// Filtered states mean "never show this" — the item must not reach the published list.
    @Test func filteredMethodsAreNotPublished() throws {
        let checkout = try checkout(
            amount: 10,
            protocols: TestSessions.cardProtocol(settings: ["payment_min_amount": 50])
        )
        #expect(checkout.paymentMethods.isEmpty)
    }

    // MARK: Selecting a primary

    @Test func selectingAPrimaryFulfilsTheSplit() throws {
        let checkout = try checkout()
        try checkout.setPrimary(try firstPrimary(checkout))

        #expect(checkout.isPaymentFulfilled)
        #expect(checkout.amountSplit.count == 1)
        #expect(checkout.amountSplit[0].amount == 100)
    }

    @Test func clearingThePrimaryEmptiesTheSplit() throws {
        let checkout = try checkout()
        try checkout.setPrimary(try firstPrimary(checkout))
        checkout.clearPrimarySplit()

        #expect(!checkout.isPaymentFulfilled)
        #expect(checkout.amountSplit.isEmpty)
    }

    /// Web's `setAsPrimarySource` refuses a disabled method; so does this.
    @Test func selectingADisabledMethodIsRefused() throws {
        let checkout = try checkout(
            amount: 100,
            protocols: TestSessions.cardProtocol(settings: ["payment_max_amount": 50])
        )
        let method = try firstPrimary(checkout)
        #expect(method.disabled?.code == .maxAmountExceeded)

        #expect(throws: PurseCheckoutError.self) { try checkout.setPrimary(method) }
    }

    // MARK: Secondaries

    @Test func applyingAGiftCardReducesWhatIsLeft() throws {
        let checkout = try checkout()
        try checkout.applySecondary(giftCard(balance: 200), amount: 30)

        #expect(checkout.remainingAmountToPay == 70)
        #expect(checkout.appliedSecondaries.count == 1)
    }

    @Test func removingAGiftCardRestoresWhatIsLeft() throws {
        let checkout = try checkout()
        let token = giftCard(balance: 200)
        try checkout.applySecondary(token, amount: 30)
        checkout.removeSecondary(token)

        #expect(checkout.remainingAmountToPay == 100)
        #expect(checkout.appliedSecondaries.isEmpty)
    }

    @Test func aGiftCardCoveringEverythingFulfilsWithoutAPrimary() throws {
        let checkout = try checkout()
        try checkout.applySecondary(giftCard(balance: 100), amount: 100)

        #expect(checkout.remainingAmountToPay == 0)
        #expect(checkout.isPaymentFulfilled)
    }

    /// The in-split exemption: covering the amount must not disable the very method covering it,
    /// or a fully-covered gift card would disable itself and could never be adjusted.
    @Test func aMethodInTheSplitIsNotDisabledByItsOwnCoverage() throws {
        let protocols: [String: Any] = [
            "purse": ["creditcard": ["configurations": ["stable": true, "labels": [], "settings": [:]]]],
            "illicado": ["giftcard": ["configurations": ["stable": true, "labels": ["secondary"], "settings": [:]]]],
        ]
        let checkout = try checkout(protocols: protocols)
        try checkout.applySecondary(giftCard(balance: 100), amount: 100)

        let byId = Dictionary(uniqueKeysWithValues: checkout.paymentMethods.map { ($0.id, $0) })
        // The gift card method is in the split, so it is exempt...
        #expect(byId["illicado-giftcard"]?.disabled == nil)
        // ...while the card method, which is not, is disabled as fulfilled.
        #expect(byId["purse-creditcard"]?.disabled?.code == .paymentFulfilled)
    }

    @Test func fulfilmentDisablesOtherMethodsAndIsReversible() throws {
        let checkout = try checkout()
        let token = giftCard(balance: 100)

        try checkout.applySecondary(token, amount: 100)
        #expect(checkout.paymentMethods[0].disabled?.code == .paymentFulfilled)

        checkout.removeSecondary(token)
        #expect(checkout.paymentMethods[0].disabled == nil)
    }

    // MARK: Fulfilment gate

    /// A covered split is necessary but not sufficient — a form that reports incomplete blocks it.
    @Test func anIncompleteFormBlocksFulfilment() throws {
        let checkout = try checkout()
        let method = try firstPrimary(checkout)
        try checkout.setPrimary(method)
        #expect(checkout.isPaymentFulfilled)

        checkout.setFulfilled(method.id, false)
        #expect(!checkout.isPaymentFulfilled)
        #expect(checkout.unfulfilledItemId == method.id)

        checkout.setFulfilled(method.id, true)
        #expect(checkout.isPaymentFulfilled)
    }

    // MARK: setSession

    private func refreshedWidgetData(id: String, amount: Any = 200, protocols: [String: Any]? = nil) -> String {
        TestSessions.widgetData(
            paymentSession: TestSessions.paymentSession(
                id: id,
                amount: amount,
                protocols: protocols ?? TestSessions.cardProtocol()
            )
        )
    }

    @Test func setSessionReplacesTheAmount() throws {
        let checkout = try checkout()
        try checkout.setSession(refreshedWidgetData(id: "session-2"))

        #expect(checkout.currentSessionId == "session-2")
        #expect(checkout.remainingAmountToPay == 200)
        #expect(checkout.sessionState == .ready)
    }

    /// An unchanged method keeps its place as the primary, so the screen does not reset.
    @Test func anUnchangedPrimarySurvivesSetSession() throws {
        let checkout = try checkout()
        try checkout.setPrimary(try firstPrimary(checkout))

        try checkout.setSession(refreshedWidgetData(id: "session-2"))

        #expect(checkout.amountSplit.count == 1)
        #expect(checkout.amountSplit[0].source.id == "purse-creditcard")
        #expect(checkout.amountSplit[0].amount == 200)
    }

    /// A method whose configuration changed is a different method wearing the same id.
    @Test func aChangedPrimaryIsTornDownAndItsGenerationBumped() throws {
        let checkout = try checkout()
        try checkout.setPrimary(try firstPrimary(checkout))

        try checkout.setSession(refreshedWidgetData(
            id: "session-2",
            protocols: TestSessions.cardProtocol(settings: ["save_token": true])
        ))

        #expect(checkout.amountSplit.isEmpty)
        #expect(checkout.itemGenerations["purse-creditcard"] == 1)
    }

    /// Gift cards were tokenized against the old session and cannot carry over.
    @Test func appliedGiftCardsAreDroppedBySetSession() throws {
        let checkout = try checkout()
        try checkout.applySecondary(giftCard(balance: 200), amount: 30)

        try checkout.setSession(refreshedWidgetData(id: "session-2"))

        #expect(checkout.appliedSecondaries.isEmpty)
        #expect(checkout.remainingAmountToPay == 200)
    }

    @Test func setSessionRefusesAnAlreadyExpiredSession() throws {
        let checkout = try checkout()
        let expired = TestSessions.widgetData(
            paymentSession: TestSessions.paymentSession(id: "session-2", expirationDate: "2000-01-01T00:00:00Z")
        )

        #expect(throws: PurseCheckoutError.self) { try checkout.setSession(expired) }
        // The old session stays in force.
        #expect(checkout.currentSessionId == "session-1")
    }

    /// Same id → ignored, as on web.
    @Test func setSessionIgnoresTheSameSessionId() throws {
        let checkout = try checkout()
        try checkout.setSession(refreshedWidgetData(id: "session-1", amount: 999))
        #expect(checkout.remainingAmountToPay == 100)
    }

    @Test func setSessionReappliesDisabledMethods() throws {
        let checkout = try checkout(disabledMethods: [MethodKey(partner: .purse, method: .creditCard)])
        #expect(checkout.paymentMethods.isEmpty)

        try checkout.setSession(refreshedWidgetData(id: "session-2"))
        #expect(checkout.paymentMethods.isEmpty)
    }

    /// The instance id is what correlates a merchant's logs with Purse monitoring across a refresh.
    @Test func theInstanceIdSurvivesSetSession() throws {
        let checkout = try checkout()
        let instanceId = checkout.instanceId

        try checkout.setSession(refreshedWidgetData(id: "session-2"))
        #expect(checkout.instanceId == instanceId)
    }
}
