// Web: packages/headless-checkout/src/session/payment/splitter/payment-splitter.ts
// Same: one primary + N secondaries, secondaries first, primary absorbs the rest; take-policy and usage-limit refusals.
// Differs: integer cents; no autofill middlewares; a value type rather than a class.

import Foundation

/// The payment split for a session. Model: **one primary + N secondaries**. Applied secondary
/// tokens (gift cards, vouchers) are drawn down first; the primary absorbs whatever is left
/// (``primaryReach``).
public struct PursePaymentSplitter: Sendable {

    private var amountCents: Int64
    private var primary: (any PrimarySource)?
    /// Applied secondary tokens with their slice, in insertion order. An array rather than a
    /// dictionary because order is part of the contract and the count is tiny.
    private var secondaries: [(token: SecondaryToken, cents: Int64)] = []

    public init(orderAmount: Decimal) {
        self.amountCents = Self.toCents(orderAmount)
    }

    // MARK: Reading the split

    public var orderAmount: Decimal { Self.fromCents(amountCents) }

    /// Total already covered by applied secondaries, never more than the order amount.
    public var secondaryContribution: Decimal { Self.fromCents(secondaryContributionCents) }

    /// Amount a primary still has to pay — order minus what secondaries cover, floored at zero.
    public var primaryReach: Decimal { Self.fromCents(remainingCents) }

    /// Alias of ``primaryReach``, the amount still owed.
    public var remaining: Decimal { primaryReach }

    /// The current primary — a method or a saved token.
    public var primaryMethod: (any PrimarySource)? { primary }

    /// The applied secondary tokens, in the order they were added.
    public var appliedSecondaries: [SecondaryToken] { secondaries.map(\.token) }

    /// True once payment can be submitted: secondaries covering the whole (non-zero) amount, or a
    /// primary selected to cover the remainder.
    public var fulfilled: Bool { primary != nil || (amountCents > 0 && remainingCents == 0) }

    /// The submittable set: each applied token's slice, plus the primary's remainder when one is set.
    public var splits: [PaymentSplit] {
        var list = secondaries.map { PaymentSplit(amount: Self.fromCents($0.cents), source: $0.token) }
        if let primary, remainingCents > 0 {
            list.append(PaymentSplit(amount: Self.fromCents(remainingCents), source: primary))
        }
        return list
    }

    // MARK: Mutating the split

    public mutating func setPrimary(_ source: (any PrimarySource)?) {
        primary = source
    }

    /// Draw an applied `token` down against what is left. With no `requestedAmount` the draw is the
    /// most the token can cover: its balance, the method's `payment_max_amount` and the remaining
    /// amount.
    public mutating func takeSplit(_ token: SecondaryToken, requestedAmount: Decimal? = nil) throws {
        let alreadyThis = secondaries.first { $0.token.id == token.id }?.cents ?? 0
        let remainingWithoutThis = amountCents - (rawSecondarySumCents - alreadyThis)
        let limitCents = token.limit.map(Self.toCents) ?? Int64.max
        let cap = max(0, min(Self.toCents(token.balance), remainingWithoutThis, limitCents))

        if alreadyThis == 0, let usageLimit = token.usageLimit, usageLimit > 0 {
            let sameMethod = secondaries.filter {
                $0.token.partner == token.partner && $0.token.method == token.method
            }.count
            if sameMethod >= usageLimit {
                throw PurseCheckoutError.invalidTake(
                    "\(token.partner.wireValue)/\(token.method.wireValue) can be used at most "
                        + "\(usageLimit) time(s) per session",
                    .usageLimitError
                )
            }
        }

        let take: Int64 = switch token.takePolicy {
        case .max:
            cap
        case .none:
            try requestedAmount.map {
                try checkedTake(
                    Self.toCents($0),
                    token: token,
                    remainingWithoutThis: remainingWithoutThis,
                    limitCents: limitCents
                )
            } ?? cap
        }

        secondaries.removeAll { $0.token.id == token.id }
        if take != 0 {
            secondaries.append((token, take))
        }
    }

    private func checkedTake(
        _ requested: Int64,
        token: SecondaryToken,
        remainingWithoutThis: Int64,
        limitCents: Int64
    ) throws -> Int64 {
        func invalid(_ reason: String) -> PurseCheckoutError {
            .invalidTake(
                "cannot take \(Self.fromCents(requested).plainString) from \(token.id): \(reason)",
                .invalidTakeAmount
            )
        }
        if requested < 0 {
            throw invalid("amount must be positive")
        }
        if requested > remainingWithoutThis {
            throw invalid("only \(Self.fromCents(remainingWithoutThis).plainString) is left to pay")
        }
        if requested > Self.toCents(token.balance) {
            throw invalid("balance is \(token.balance.plainString)")
        }
        if requested > limitCents {
            throw PurseCheckoutError.invalidTake(
                "cannot take \(Self.fromCents(requested).plainString) from \(token.id): "
                    + "the method's maximum is \(Self.fromCents(limitCents).plainString)",
                .maxAmountReached
            )
        }
        return requested
    }

    public mutating func clearSplit(_ token: SecondaryToken) {
        secondaries.removeAll { $0.token.id == token.id }
    }

    /// Reset to a fresh order amount, dropping the primary and every applied secondary.
    public mutating func reset(orderAmount: Decimal) {
        amountCents = Self.toCents(orderAmount)
        primary = nil
        secondaries.removeAll()
    }

    // MARK: Cents

    private var rawSecondarySumCents: Int64 { secondaries.reduce(0) { $0 + $1.cents } }
    private var secondaryContributionCents: Int64 { min(rawSecondarySumCents, amountCents) }
    private var remainingCents: Int64 { max(0, amountCents - secondaryContributionCents) }

    /// Major units → integer cents, rounding half away from zero (Kotlin's `HALF_UP`).
    static func toCents(_ amount: Decimal) -> Int64 {
        var scaled = amount * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    /// Back to a 2-dp major-unit value, e.g. 3000 → `30.00`.
    static func fromCents(_ cents: Int64) -> Decimal {
        Decimal(cents) / 100
    }
}
