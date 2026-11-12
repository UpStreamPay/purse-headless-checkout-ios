// Web: packages/headless-checkout/src/utils/redirection-log.ts (`getRedirectionHostname`, `logRedirection`)
// Same: `HEADLESS_CHECKOUT_REDIRECTION` payload — exactly one of `url` / `action` / `string_form`, hostname only, Widget V3's "couldn't parse the url".
// Differs: `.get` is always `url` (web logs a GET built through `submitRedirectionForm` as `action`); `delegated` is what the `onRedirection` hook answered, not whether a hook is set — see `presentRedirectIfNeeded`.

import Foundation

/// Logged in place of a hostname when the destination has none to read. Widget V3's text.
let unparseableRedirectionHost = "couldn't parse the url"

/// The hostname only, lowercased as web's `URL.hostname` is: the path, query string and fragment
/// can carry payment or shopper data.
func redirectionHostname(_ url: String) -> String {
    guard let host = URLComponents(string: url)?.host?.lowercased(), !host.isEmpty else {
        return unparseableRedirectionHost
    }
    return host
}

/// The `HEADLESS_CHECKOUT_REDIRECTION` payload for `action`. Never carries the form data or the
/// markup, only where the shopper is sent.
func redirectionPayload(for action: RedirectAction, delegated: Bool) -> JSONValue {
    var pairs: [String: JSONValue?] = ["delegated": .bool(delegated)]
    switch action {
    case let .get(url, _):
        pairs["url"] = .string(redirectionHostname(url))
    case let .postForm(url, _, _):
        pairs["action"] = .string(redirectionHostname(url))
    case .postHTML:
        // Markup from the API: no URL to read without parsing a form we must not log.
        pairs["string_form"] = .bool(true)
    }
    return monitoringPayload(pairs)
}
