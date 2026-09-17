// Web: none — web lands on the merchant's success page.
// Same: —
// Differs: a typed status over the session's transactions, for the screen the app returns to.
// Android: eu.purse.checkout.confirmation.PaymentSessionStatus

import Foundation

/// One row from `GET /{entityId}/sessions/{sessionId}` — an **operation, not a payment**.
///
/// `action` and `state` stay `String`: the server owns both vocabularies, and a value this SDK has
/// never heard of must not fail the decode.
public struct TransactionOperation: Sendable, Equatable {
    public let partner: String
    public let method: String
    /// `INIT` / `APPLY` / `AUTHORIZE` / `CAPTURE` / `VOID` / `REFUND`.
    public let action: String
    /// `SUCCESS` / `ERROR` / `UNCERTAIN` / `FAILED` / `WAITING`.
    public let state: String
    public let code: String?
    public let id: String?
    /// Links a v2 `CAPTURE` row back to its `AUTHORIZE` row.
    public let parentTransactionId: String?
    public let partnerReference: String?

    public init(
        partner: String,
        method: String,
        action: String,
        state: String,
        code: String? = nil,
        id: String? = nil,
        parentTransactionId: String? = nil,
        partnerReference: String? = nil
    ) {
        self.partner = partner
        self.method = method
        self.action = action
        self.state = state
        self.code = code
        self.id = id
        self.parentTransactionId = parentTransactionId
        self.partnerReference = partnerReference
    }
}

/// What the session's transactions say about the payment — the settled answer that
/// ``PaymentOutcome/returnedFromRedirect(url:)`` deliberately is not.
///
/// Two limits, both shared with Android. A session holding only failed `INIT` rows reads `.pending`,
/// not `.failed`, which is right: a method that would not initialise has not spent the session, and
/// the shopper can still pay with another. And a successful authorization later reversed by a `VOID`
/// still reads `.confirmed` — untangling that needs `parentTransactionId` chaining neither platform
/// does today.
public enum PaymentSessionStatus: Sendable, Equatable {
    /// A successful `AUTHORIZE` or `CAPTURE` exists — the payment went through.
    case confirmed([TransactionOperation])
    /// Money movement failed, with no success in sight.
    case failed([TransactionOperation])
    /// Nothing settled yet: only inits, or `WAITING` / `UNCERTAIN` states.
    case pending([TransactionOperation])

    public var operations: [TransactionOperation] {
        switch self {
        case let .confirmed(operations), let .failed(operations), let .pending(operations):
            return operations
        }
    }

    private static let moneyActions: Set<String> = ["AUTHORIZE", "CAPTURE"]
    private static let failedStates: Set<String> = ["ERROR", "FAILED"]

    /// Classify a raw ``PurseHeadlessCheckout/sessionTransactions()`` response.
    ///
    /// Keyed on *any* successful money operation rather than a row count: Payment API v2 lists an
    /// auto-captured payment as both an `AUTHORIZE` and a `CAPTURE`, where v1 sends one row.
    public static func from(_ transactions: [JSONValue]) -> PaymentSessionStatus {
        let operations = parse(transactions)
        let money = operations.filter { moneyActions.contains($0.action) }
        if money.contains(where: { $0.state == "SUCCESS" }) {
            return .confirmed(operations)
        }
        if !money.isEmpty, money.allSatisfy({ failedStates.contains($0.state) }) {
            return .failed(operations)
        }
        return .pending(operations)
    }

    /// A row with no `status` is skipped rather than failing the parse — one unreadable row must not
    /// cost the caller the answer about their money.
    public static func parse(_ transactions: [JSONValue]) -> [TransactionOperation] {
        transactions.compactMap { row in
            guard let status = row["status"], status.objectValue != nil else { return nil }
            return TransactionOperation(
                partner: row["partner"]?.stringValue ?? "",
                method: row["method"]?.stringValue ?? "",
                action: status["action"]?.stringValue ?? "",
                state: status["state"]?.stringValue ?? "",
                code: status["code"]?.stringValue.nonBlank,
                id: row["id"]?.stringValue.nonBlank,
                parentTransactionId: row["parent_transaction_id"]?.stringValue.nonBlank,
                partnerReference: row["plugin_result"]?["partner_reference"]?.stringValue.nonBlank
            )
        }
    }
}

private extension Optional where Wrapped == String {
    /// `""` and `nil` mean the same thing on this wire.
    var nonBlank: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
