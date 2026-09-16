// Web: none — web navigates the page itself.
// Same: —
// Differs: a presenter the host drives. Android uses an in-app WebView for every case; iOS uses ASWebAuthenticationSession for the GET case, which is a real browser and so is not refused by ACS providers that detect embedded web views.

import Foundation

/// How a presented redirect ended. Note what is **not** here: success.
public enum RedirectOutcome: Sendable, Equatable {
    /// The shopper reached the return destination, or came back to the app at all. `url` is what
    /// they came back to, when the presenter could see it — the browser reports its callback and
    /// the web view reports the navigation it stopped on.
    case returned(url: URL?)
    /// The shopper dismissed the flow.
    case canceled
}

/// Presents a ``RedirectAction`` and reports how it ended.
///
/// Implement this to take redirects over yourself; otherwise ``WebAuthRedirectPresenter`` is used.
@MainActor
public protocol RedirectPresenter {
    func present(_ action: RedirectAction) async throws -> RedirectOutcome
}

/// Where a redirect is allowed to send the shopper, and what counts as coming back.
public struct RedirectPolicy: Sendable {

    /// How the shopper gets back to the app.
    public enum Return: Sendable, Equatable {
        /// A Universal Link your app claims, e.g. `checkout.example.com` + `/purse/return`.
        /// Preferred: a Universal Link can only be claimed by the app that owns the domain, so
        /// another app cannot fabricate a return.
        case universalLink(host: String, path: String)
        /// A custom URL scheme, e.g. `myapp-purse`. Simpler to configure, but any app can register
        /// the same scheme — which is why reaching it is still only ever *returned*, never approved.
        case customScheme(String)
    }

    public let returnDestination: Return
    /// Extra hosts the redirect chain may visit, beyond the `https` rule below.
    public let additionalAllowedHosts: Set<String>

    public init(returnDestination: Return, additionalAllowedHosts: Set<String> = []) {
        self.returnDestination = returnDestination
        self.additionalAllowedHosts = additionalAllowedHosts
    }

    /// Whether a URL may be loaded at all. `https` only.
    public func allowsLoading(_ url: URL) -> Bool {
        if isReturn(url) { return true }
        guard url.scheme?.lowercased() == "https" else { return false }
        guard !additionalAllowedHosts.isEmpty else { return true }
        guard let host = url.host?.lowercased() else { return false }
        return additionalAllowedHosts.contains(host)
    }

    /// Whether reaching this URL means the shopper came back.
    public func isReturn(_ url: URL) -> Bool {
        switch returnDestination {
        case let .universalLink(host, path):
            return url.scheme?.lowercased() == "https"
                && url.host?.lowercased() == host.lowercased()
                && url.path.hasPrefix(path)
        case let .customScheme(scheme):
            return url.scheme?.lowercased() == scheme.lowercased()
        }
    }

    /// The callback scheme `ASWebAuthenticationSession` matches on, when the policy uses one.
    var callbackScheme: String? {
        if case let .customScheme(scheme) = returnDestination { return scheme }
        return nil
    }
}
