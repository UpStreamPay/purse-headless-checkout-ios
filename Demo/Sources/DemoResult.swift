import Foundation
import PurseHeadlessCheckout

/// What the result screen shows. Three states, not two: a redirect return is neither a success nor
/// a failure until the session says so.
struct DemoResult {
    enum Kind { case authorized, failed, unconfirmed }

    let kind: Kind
    let method: String
    let detail: String

    var title: String {
        switch kind {
        case .authorized: "Payment authorized"
        case .failed: "Payment failed"
        case .unconfirmed: "Outcome unconfirmed"
        }
    }

    var symbol: String {
        switch kind {
        case .authorized: "checkmark"
        case .failed: "xmark"
        case .unconfirmed: "exclamationmark"
        }
    }

    static func from(_ outcome: PaymentOutcome, method: String) -> DemoResult? {
        switch outcome {
        case let .completed(result):
            return DemoResult(
                kind: result.isSuccess ? .authorized : .failed,
                method: method,
                detail: "global_status = \(result.globalStatus)"
            )
        case .returnedFromRedirect:
            return DemoResult(
                kind: .unconfirmed,
                method: method,
                detail: "The shopper came back from the partner's redirect, which isn't proof of "
                    + "payment. Fetch the transactions below to confirm."
            )
        case let .failed(error):
            return DemoResult(kind: .failed, method: method, detail: "\(error)")
        case .canceled:
            // Not a result: the shopper may try again on the same screen.
            return nil
        }
    }

    /// Promote to authorized when alfred's transactions say the payment really landed — the same
    /// check Android's `confirmOutcomeFrom` makes, and the only honest way to resolve a redirect.
    func confirmed(by transactions: [DemoJSON]) -> DemoResult {
        let authorized = transactions.contains { transaction in
            let status = transaction["status"]
            let action = status?["action"]?.string ?? ""
            let state = status?["state"]?.string ?? ""
            return ["AUTHORIZE", "CAPTURE"].contains(action) && state == "SUCCESS"
        }
        guard authorized else { return self }
        return DemoResult(kind: .authorized, method: method, detail: "confirmed from the session's transactions")
    }
}
