// Web: packages/headless-checkout/src/headless-checkout-validation.ts `summarizeValidationResults`
// Same: field allowlist per attempt, caps, `onlyFailures`.
// Differs: no `stack` field on `errorPayload` — Swift errors carry no call-stack capture the way a JVM `Throwable` does, and there is no reliable substitute worth faking.

import Foundation

/// Attempts kept per event — a split is a handful of items; anything beyond this is a runaway response.
private let maxSummarizedResults = 5
/// `status.description` is the only free-text field the API returns per attempt, so it is the only one capped.
private let maxDescriptionLength = 200
/// An exception message is free text (partner wording, merchant wording): capped like a description, wider.
private let maxMessageLength = 500

/// A monitoring payload from non-`nil` pairs — Swift's analog of Kotlin's `vararg Pair<String, Any?>`
/// helper. A key whose value is `nil` is dropped entirely, never encoded as `null`.
func monitoringPayload(_ pairs: [String: JSONValue?]) -> JSONValue {
    var object: [String: JSONValue] = [:]
    for (key, value) in pairs {
        if let value { object[key] = value }
    }
    return .object(object)
}

/// Flattens a `/validate` response into the per-attempt detail the monitoring events carry:
/// `method`, `partner`, `status { state, code, description }` and `plugin_status` — the partner-
/// side outcome behind the Purse status code, without which a technical-issue code caused by a
func summarizeValidationResults(_ response: JSONValue?, onlyFailures: Bool = false) -> JSONValue {
    guard let results = response?["results"]?.arrayValue else { return .array([]) }

    let attempts = results
        .filter { !onlyFailures || $0["status"]?["state"]?.stringValue != "SUCCESS" }
        .prefix(maxSummarizedResults)

    return .array(attempts.map { result in
        let status = result["status"]
        return monitoringPayload([
            "method": result["method"]?.stringValue.map(JSONValue.string),
            "partner": result["partner"]?.stringValue.map(JSONValue.string),
            "status": monitoringPayload([
                "state": status?["state"]?.stringValue.map(JSONValue.string),
                "code": status?["code"]?.stringValue.map(JSONValue.string),
                "description": status?["description"]?.stringValue.map {
                    .string(String($0.prefix(maxDescriptionLength)))
                }
            ]),
            "plugin_status": result["plugin_result"]?["status"]?.stringValue.map(JSONValue.string)
        ])
    })
}

/// The payload of an error-shaped event for `error`: a capped `message`, the stable Purse `code`
/// when there is one, and — when a Payment API call is the cause, anywhere down the chain — which
/// call (`api_path`), how it answered (`api_status`, `api_error`) and whether the answer never came
func errorPayload(_ error: any Error, message: String? = nil, extra: [String: JSONValue?] = [:]) -> JSONValue {
    let purseError = error as? any PurseError
    let resolvedMessage = message ?? purseError?.message ?? String(describing: error)
    let apiError = firstPaymentAPIError(in: error)

    var pairs: [String: JSONValue?] = [
        "message": .string(String(resolvedMessage.prefix(maxMessageLength))),
        "code": purseError.map { .string($0.code.rawValue) },
        "api_path": apiError?.path.map(JSONValue.string),
        "api_status": apiError?.status.map { .number(String($0)) },
        "api_error": apiError?.errorCode.map(JSONValue.string),
        "outcome_unknown": (apiError?.outcomeUnknown == true) ? .bool(true) : nil
    ]
    for (key, value) in extra { pairs[key] = value }
    return monitoringPayload(pairs)
}

/// Walks `error`'s `underlying` chain (``PurseError/underlying``) for the first ``PaymentAPIError``
/// — web's/Android's `cause` walk, bounded so a (impossible, but never trusted) cycle cannot loop.
private func firstPaymentAPIError(in error: any Error) -> PaymentAPIError? {
    var current: (any Error)? = error
    var steps = 0
    while let candidate = current, steps < 10 {
        if let apiError = candidate as? PaymentAPIError { return apiError }
        current = (candidate as? any PurseError)?.underlying
        steps += 1
    }
    return nil
}
