import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// The money maths. Vectors are ported from web's own suite (`usp-widget/packages/headless-
/// checkout/src/headless-checkout.splits.test.ts` and `.secondary-tokens.test.ts`) — same inputs
/// must produce the same cents, which is the acceptance criterion of SDK-12260.
struct SplitterTests {

    private func giftCard(
        id: String = "gift-1",
        balance: Decimal,
        takePolicy: SecondaryTakePolicy = .none,
        limit: Decimal? = nil,
        usageLimit: Int? = nil
    ) -> SecondaryToken {
        SecondaryToken(
            id: id,
            partner: .illicado,
            method: .giftCard,
            pan: "9250004787002023349",
            cvv: "123",
            name: "gift card",
            balance: balance,
            takePolicy: takePolicy,
            limit: limit,
            usageLimit: usageLimit
        )
    }

    private struct StubPrimary: PrimarySource {
        let id = "purse-creditcard"
        let partner = Partner.purse
        let method = PaymentMethod.creditCard
    }

    // MARK: Web vectors

    /// Web: order 480, take 10 → one split of 10, remaining 470; remove → remaining 480.
    @Test func takeThenRemoveMatchesWeb() throws {
        var splitter = PursePaymentSplitter(orderAmount: 480)
        let token = giftCard(balance: Decimal(string: "213.62")!)

        try splitter.takeSplit(token, requestedAmount: 10)
        #expect(splitter.splits.count == 1)
        #expect(splitter.splits[0].amount == 10)
        #expect(splitter.remaining == 470)

        splitter.clearSplit(token)
        #expect(splitter.splits.isEmpty)
        #expect(splitter.remaining == 480)
    }

    /// Web: taking the whole session amount fulfils the payment with no primary at all.
    @Test func coveringTheAmountFulfilsWithoutAPrimary() throws {
        var splitter = PursePaymentSplitter(orderAmount: 480)
        try splitter.takeSplit(giftCard(balance: 480), requestedAmount: 480)

        #expect(splitter.remaining == 0)
        #expect(splitter.fulfilled)
    }

    /// Web: a refused take leaves the split untouched — it throws rather than clamping.
    @Test func refusedTakesLeaveTheSplitUntouched() throws {
        var splitter = PursePaymentSplitter(orderAmount: 480)
        let token = giftCard(balance: 100)

        #expect(throws: PurseCheckoutError.self) { try splitter.takeSplit(token, requestedAmount: 110) }
        #expect(throws: PurseCheckoutError.self) { try splitter.takeSplit(token, requestedAmount: -1) }
        #expect(splitter.remaining == 480)
        #expect(splitter.splits.isEmpty)
    }

    @Test func cannotTakeMoreThanTheSessionTotal() {
        var splitter = PursePaymentSplitter(orderAmount: 480)
        #expect(throws: PurseCheckoutError.self) {
            try splitter.takeSplit(giftCard(balance: 1000), requestedAmount: 490)
        }
    }

    /// Web: usage limit 2 — a third instrument of the same method is refused.
    @Test func usageLimitRefusesTheThirdInstrument() throws {
        var splitter = PursePaymentSplitter(orderAmount: 480)
        try splitter.takeSplit(giftCard(id: "g1", balance: 100, usageLimit: 2), requestedAmount: 10)
        try splitter.takeSplit(giftCard(id: "g2", balance: 100, usageLimit: 2), requestedAmount: 20)

        let third = giftCard(id: "g3", balance: 100, usageLimit: 2)
        #expect(throws: PurseCheckoutError.self) { try splitter.takeSplit(third, requestedAmount: 30) }

        do {
            try splitter.takeSplit(third, requestedAmount: 30)
        } catch let error as PurseCheckoutError {
            #expect(error.code == .usageLimitError)
        }
    }

    /// Web: `test.each([0, undefined])('Limit at %s is considered unlimited')`.
    @Test(arguments: [nil, 0])
    func aZeroOrAbsentUsageLimitIsUnlimited(_ usageLimit: Int?) throws {
        var splitter = PursePaymentSplitter(orderAmount: 480)
        for index in 0 ..< 5 {
            try splitter.takeSplit(
                giftCard(id: "g\(index)", balance: 100, usageLimit: usageLimit),
                requestedAmount: 10
            )
        }
        #expect(splitter.splits.count == 5)
        #expect(splitter.remaining == 430)
    }

    @Test func exceedingTheMethodMaximumReportsItsOwnCode() {
        var splitter = PursePaymentSplitter(orderAmount: 480)
        do {
            try splitter.takeSplit(giftCard(balance: 400, limit: 50), requestedAmount: 100)
            Issue.record("expected the take to be refused")
        } catch let error as PurseCheckoutError {
            #expect(error.code == .maxAmountReached)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: Take policies

    /// A splittable gift card with no requested amount takes the most it can.
    @Test func noneTakesTheCapWhenNoAmountIsRequested() throws {
        var splitter = PursePaymentSplitter(orderAmount: 480)
        try splitter.takeSplit(giftCard(balance: 100))
        #expect(splitter.remaining == 380)
    }

    /// Non-splittable loyalty ignores the requested amount entirely and takes the cap.
    @Test func maxIgnoresTheRequestedAmount() throws {
        var splitter = PursePaymentSplitter(orderAmount: 480)
        try splitter.takeSplit(giftCard(balance: 100, takePolicy: .max), requestedAmount: 10)
        #expect(splitter.remaining == 380)
    }

    /// The cap is the smallest of balance, what is left, and the method maximum.
    @Test func theCapIsBoundedByWhatIsLeftToPay() throws {
        var splitter = PursePaymentSplitter(orderAmount: 50)
        try splitter.takeSplit(giftCard(balance: 100, takePolicy: .max))
        #expect(splitter.remaining == 0)
        #expect(splitter.splits[0].amount == 50)
    }

    @Test func theCapIsBoundedByTheMethodMaximum() throws {
        var splitter = PursePaymentSplitter(orderAmount: 480)
        try splitter.takeSplit(giftCard(balance: 400, takePolicy: .max, limit: 50))
        #expect(splitter.remaining == 430)
    }

    // MARK: Re-applying and removal

    @Test func reapplyingReplacesThePriorSlice() throws {
        var splitter = PursePaymentSplitter(orderAmount: 480)
        let token = giftCard(balance: 200)

        try splitter.takeSplit(token, requestedAmount: 10)
        try splitter.takeSplit(token, requestedAmount: 30)

        #expect(splitter.splits.count == 1)
        #expect(splitter.remaining == 450)
    }

    /// A re-apply must be measured against the amount *without* its own prior slice, or a token
    /// could never be raised to cover the whole remainder.
    @Test func reapplyingCanTakeTheWholeRemainder() throws {
        var splitter = PursePaymentSplitter(orderAmount: 100)
        let token = giftCard(balance: 200)

        try splitter.takeSplit(token, requestedAmount: 40)
        try splitter.takeSplit(token, requestedAmount: 100)

        #expect(splitter.remaining == 0)
    }

    @Test func takingZeroRemovesTheToken() throws {
        var splitter = PursePaymentSplitter(orderAmount: 480)
        let token = giftCard(balance: 200)

        try splitter.takeSplit(token, requestedAmount: 10)
        try splitter.takeSplit(token, requestedAmount: 0)

        #expect(splitter.splits.isEmpty)
        #expect(splitter.remaining == 480)
    }

    // MARK: Primary

    @Test func thePrimaryAbsorbsTheRemainder() throws {
        var splitter = PursePaymentSplitter(orderAmount: 480)
        try splitter.takeSplit(giftCard(balance: 100), requestedAmount: 80)
        splitter.setPrimary(StubPrimary())

        #expect(splitter.splits.count == 2)
        #expect(splitter.splits.last?.amount == 400)
        #expect(splitter.fulfilled)
    }

    /// Once secondaries cover everything the primary contributes no slice, even while selected.
    @Test func aFullyCoveredSplitGivesThePrimaryNoSlice() throws {
        var splitter = PursePaymentSplitter(orderAmount: 100)
        splitter.setPrimary(StubPrimary())
        try splitter.takeSplit(giftCard(balance: 100), requestedAmount: 100)

        #expect(splitter.splits.count == 1)
        #expect(splitter.remaining == 0)
    }

    /// A zero-amount session is never fulfilled by itself — an information request still needs the
    /// primary the shopper is registering.
    @Test func aZeroAmountSessionNeedsAPrimary() {
        var splitter = PursePaymentSplitter(orderAmount: 0)
        #expect(!splitter.fulfilled)

        splitter.setPrimary(StubPrimary())
        #expect(splitter.fulfilled)
    }

    @Test func resetDropsEverything() throws {
        var splitter = PursePaymentSplitter(orderAmount: 480)
        try splitter.takeSplit(giftCard(balance: 100), requestedAmount: 50)
        splitter.setPrimary(StubPrimary())

        splitter.reset(orderAmount: 200)

        #expect(splitter.orderAmount == 200)
        #expect(splitter.remaining == 200)
        #expect(splitter.primaryMethod == nil)
        #expect(splitter.appliedSecondaries.isEmpty)
    }

    // MARK: Cents

    /// The whole reason the splitter works in integer cents.
    @Test(arguments: [
        ("0.01", Int64(1)), ("0.07", 7), ("42.50", 4250), ("1000.00", 100_000), ("19.99", 1999),
    ])
    func decimalsConvertToExactCents(_ literal: String, _ expected: Int64) {
        #expect(PursePaymentSplitter.toCents(Decimal(string: literal)!) == expected)
    }

    /// Rounds half away from zero, matching Kotlin's HALF_UP.
    @Test func halfCentsRoundAwayFromZero() {
        #expect(PursePaymentSplitter.toCents(Decimal(string: "0.005")!) == 1)
        #expect(PursePaymentSplitter.toCents(Decimal(string: "0.015")!) == 2)
    }

    /// Three 0.01 takes against 0.03 must land exactly on zero — the classic float-drift case.
    @Test func manySmallTakesLandExactlyOnZero() throws {
        var splitter = PursePaymentSplitter(orderAmount: Decimal(string: "0.03")!)
        for index in 0 ..< 3 {
            try splitter.takeSplit(
                giftCard(id: "g\(index)", balance: 1),
                requestedAmount: Decimal(string: "0.01")!
            )
        }
        #expect(splitter.remaining == 0)
        #expect(splitter.fulfilled)
    }

    @Test func secondariesNeverContributeMoreThanTheOrder() throws {
        var splitter = PursePaymentSplitter(orderAmount: 100)
        try splitter.takeSplit(giftCard(balance: 100), requestedAmount: 100)

        #expect(splitter.secondaryContribution == 100)
        #expect(splitter.remaining == 0)
    }
}
