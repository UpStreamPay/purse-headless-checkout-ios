// Web: packages/partner-ui `manageRedirection` + widget confirmation-page handling
// Same: field priority over the /validate answer; `payment_id` off the confirmation URL.
// Differs: `should_submit_widget` is never auto-followed.

import Foundation

/// What a `/validate` response asks the client to do next, for genuine must-follow redirects.
public enum RedirectionResolver {

    public static func resolve(
        validateResponse: JSONValue,
        partner: String,
        method: String,
        sessionReturnURL: String? = nil
    ) -> RedirectAction? {
        let logs = pluginLogs(in: validateResponse, partner: partner, method: method)

        let redirectionJSON = logs?["redirection_json"]?.stringValue
        let redirectionURLFromLogs = logs?["redirection_url"]?.stringValue
        let redirectURLPostParams = logs?["redirect_url_post_params"]?.stringValue
        let redirection = validateResponse["redirection"]
        let globalURL = redirection?["url"]?.stringValue
        let globalForm = redirection?["form"]?.stringValue

        let action: RedirectAction?
        if let redirectionJSON, let redirectionURLFromLogs {
            // 1. Per-item POST form.
            action = .postForm(url: redirectionURLFromLogs, formDataURLEncoded: redirectionJSON)
        } else if let globalURL {
            // 2. Global URL redirect — GET, or POST with the per-item post params if also present.
            action = redirectURLPostParams.map {
                RedirectAction.postForm(url: globalURL, formDataURLEncoded: $0)
            } ?? .get(url: globalURL)
        } else if let globalForm {
            // 3. Raw HTML form string.
            action = .postHTML(html: globalForm)
        } else {
            action = nil
        }

        guard let action, let target = action.targetURL else { return action }
        let isOwnReturn = sessionReturnURL.map(target.hasPrefix) ?? false
        // Only the wallet approves natively before /validate; for bnpl this URL *is* the approval.
        let isPayPalWalletEcho = partner == "paypal" && method == "wallet" && target.isPayPalApprovalEcho
        let isEcho = target.isWidgetConfirmationRedirect || isPayPalWalletEcho
        return (isOwnReturn || isEcho) ? nil : action
    }

    /// Read off the response, so it is there even when `resolve` suppressed that same redirect.
    public static func widgetConfirmationPaymentId(
        validateResponse: JSONValue,
        partner: String = "",
        method: String = ""
    ) -> String? {
        let logs = pluginLogs(in: validateResponse, partner: partner, method: method)
        let candidates = [
            logs?["redirection_url"]?.stringValue,
            validateResponse["redirection"]?["url"]?.stringValue,
        ]
        return candidates.compactMap { $0?.widgetConfirmationPaymentId }.first
    }

    private static func pluginLogs(in response: JSONValue, partner: String, method: String) -> JSONValue? {
        guard let results = response["results"]?.arrayValue else { return nil }
        let entry = results.first {
            $0["partner"]?.stringValue == partner && $0["method"]?.stringValue == method
        }
        return entry?["plugin_result"]?["logs"]
    }
}
