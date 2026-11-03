// Web: packages/headless-checkout secondaries token shape + take-policy.ts
// Same: balance, total, pan, name, expiry, take policy.
// Differs: conforms to `SplitSource`; carries `saveTokenMode` for keep-this-card.

import Foundation

/// How much of a secondary instrument's balance may be drawn into the split.
public enum SecondaryTakePolicy: String, Sendable, CaseIterable {
    /// Splittable: any amount up to the balance (and what is left to pay) can be taken. Gift cards.
    case none
    /// Non-splittable: the whole available amount (min of balance and remaining) is taken. Loyalty.
    case max
}

/// A tokenized secondary (co-payment) instrument — e.g. a gift card the shopper added. Carries the
/// ``balance`` the splitter draws down, the ``pan``/``cvv`` needed to build the `/validate`
/// payload, and the instrument's ``takePolicy``.
public struct SecondaryToken: SplitSource, Sendable, Equatable {
    /// Stable per-instrument id — distinguishes multiple cards of the same method.
    public let id: String
    public let partner: Partner
    public let method: PaymentMethod
    public let pan: String
    public let cvv: String?
    /// Human label, e.g. a masked PAN. May be blank.
    public let name: String
    /// Spendable balance right now (what the splitter may draw down).
    public let balance: Decimal
    /// Full balance on the instrument, when the partner distinguishes it from ``balance``.
    public let totalBalance: Decimal
    /// Raw expiry as returned by the partner (format varies); blank when absent.
    public let expirationDate: String
    public let takePolicy: SecondaryTakePolicy
    /// The method's `payment_max_amount` — the most one instrument may draw, if the method sets one.
    public let limit: Decimal?
    /// The method's `usage_per_session_limit` — how many instruments of this `(partner, method)` may
    /// sit in one split; `nil` or zero means unlimited.
    public let usageLimit: Int?
    /// The method's effective save-token policy. Drives ``canBeRegistered``.
    public internal(set) var saveTokenMode: SaveTokenMode
    /// `true` when this token came from a **saved** instrument (the session's `integrated_tokens`)
    /// rather than a card the shopper just typed — a saved card is never re-registered at `/validate`.
    public let isSaved: Bool

    public init(
        id: String,
        partner: Partner,
        method: PaymentMethod,
        pan: String,
        cvv: String?,
        name: String,
        balance: Decimal,
        totalBalance: Decimal? = nil,
        expirationDate: String = "",
        takePolicy: SecondaryTakePolicy = .none,
        limit: Decimal? = nil,
        usageLimit: Int? = nil,
        saveTokenMode: SaveTokenMode = .never,
        isSaved: Bool = false
    ) {
        self.id = id
        self.partner = partner
        self.method = method
        self.pan = pan
        self.cvv = cvv
        self.name = name
        self.balance = balance
        self.totalBalance = totalBalance ?? balance
        self.expirationDate = expirationDate
        self.takePolicy = takePolicy
        self.limit = limit
        self.usageLimit = usageLimit
        self.saveTokenMode = saveTokenMode
        self.isSaved = isSaved
    }

    /// Whether the shopper can ask to keep this card for next time.
    public var canBeRegistered: Bool { !isSaved && saveTokenMode.canBeRegistered }
}
