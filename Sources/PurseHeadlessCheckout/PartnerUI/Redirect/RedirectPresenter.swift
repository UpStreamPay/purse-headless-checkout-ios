// Web: none — web navigates the page itself.
// Same: —
// Differs: a presenter the host drives. Android uses an in-app WebView throughout; iOS uses ASWebAuthenticationSession for the GET case, a real browser ACS providers do not refuse.

import Foundation

/// How a presented redirect ended. Note what is **not** here: success.
public enum RedirectOutcome: Sendable, Equatable {
    /// The shopper came back. `url` is what they came back to, when the presenter could see it.
    case returned(url: URL?)
    case canceled
}

/// Implement this to take redirects over yourself; otherwise ``WebAuthRedirectPresenter`` is used.
@MainActor
public protocol RedirectPresenter {
    func present(_ action: RedirectAction) async throws -> RedirectOutcome
}

/// Where a redirect is allowed to send the shopper, and what counts as coming back.
public struct RedirectPolicy: Sendable {

    /// How the shopper gets back to the app.
    public enum Return: Sendable, Equatable {
        /// Preferred: only the app owning the domain can claim it, so no other app can fabricate a
        /// return.
        case universalLink(host: String, path: String)
        /// Simpler to configure, but any app can register the same scheme — which is why reaching
        /// it is still only ever *returned*, never approved.
        case customScheme(String)
    }

    public let returnDestination: Return
    /// Extra hosts the redirect chain may visit, beyond the `https` rule.
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
