import Foundation
import PurseHeadlessCheckout

/// Three states, not two: a redirect return is neither a success nor a failure until the session
/// says so.
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
        case let .returnedFromRedirect(url):
            // The return URL's `purse-redirection-data` JWT reports the outcome.
            guard let status = url?.absoluteString.widgetRedirectionData?.authorizationStatus else {
                return DemoResult(
                    kind: .unconfirmed,
                    method: method,
                    detail: "The shopper came back, but the redirect reported nothing. Coming back "
                        + "isn't proof of payment — fetch the transactions below to confirm."
                )
            }
            return DemoResult(
                kind: status.uppercased() == "AUTHORIZED" ? .authorized : .failed,
                method: method,
                detail: "The redirect reported \(status). That is the redirect's own claim, not "
                    + "signature-checked here — fetch the transactions below to confirm it."
            )
        case let .failed(error):
            // A `/validate` that left the device unanswered is not a failure — the payment may well
            // exist, so it goes to the transactions lookup instead. Android does the same.
            guard !outcomeUnknown(error) else {
                return DemoResult(
                    kind: .unconfirmed,
                    method: method,
                    detail: "No answer to /validate — the payment may exist. Fetch the transactions "
                        + "below before telling anyone it failed. (\(error.message))"
                )
            }
            return DemoResult(kind: .failed, method: method, detail: "\(error)")
        case .canceled:
            // Not a result: the shopper may try again on the same screen.
            return nil
        }
    }

    /// Whether this error, or anything it wraps, left the device with no answer. Every layer wraps
    /// (`PaymentValidator` → `validateFailed`), so a cast at the top matches nothing.
    private static func outcomeUnknown(_ error: any PurseError) -> Bool {
        var current: (any Error)? = error
        while let error = current {
            if (error as? PaymentAPIError)?.outcomeUnknown == true { return true }
            current = (error as? any PurseError)?.underlying
        }
        return false
    }

    /// Promote to authorized when alfred's transactions say the payment landed — Android's
    /// `confirmOutcomeFrom` check.
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
