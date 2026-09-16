// Web: packages/headless-checkout splitter source
// Same: id, partner, method.
// Differs: nothing.

import Foundation

/// Anything that can back a ``PaymentSplit``: a ``PrimaryMethod`` or ``PaymentToken`` (which
/// absorbs the remainder), or an applied ``SecondaryToken`` (a drawn-down co-payment instrument).
public protocol SplitSource: Sendable {
    var id: String { get }
    var partner: Partner { get }
    var method: Method { get }
}

/// A ``SplitSource`` that can occupy the split's single primary slot: a fresh ``PrimaryMethod`` or a
/// saved ``PaymentToken`` — web lets both call `setAsPrimarySource`.
public protocol PrimarySource: SplitSource {}

/// One slice of the order amount assigned to a ``SplitSource``. The set of splits (applied
/// secondary tokens plus the primary's remainder) is what the create-payment pipeline submits to
/// `/validate`.
public struct PaymentSplit: Sendable {
    public let amount: Decimal
    public let source: any SplitSource

    public init(amount: Decimal, source: any SplitSource) {
        self.amount = amount
        self.source = source
    }
}

extension PaymentSplit: Equatable {
    /// Compared by the identity of the source and the slice, not by the whole source — two splits
    /// are the same split when the same instrument covers the same amount.
    public static func == (lhs: PaymentSplit, rhs: PaymentSplit) -> Bool {
        lhs.amount == rhs.amount && lhs.source.id == rhs.source.id
    }
}
