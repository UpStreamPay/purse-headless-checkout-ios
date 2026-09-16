// Web: none — web's plugin calls Klarna's JS client directly from its own closure scope.
// Same: the seam Android's `PartnerUiContext.collected[COLLECTED_AUTHORIZE]` serves.
// Differs: `collected` here is wire-safe `JSONValue` only, so the closure itself cannot travel through it the way Android's untyped `collected: Map<String, Any>` allows. This actor is the substitute: KlarnaCoordinator registers the closure keyed by an opaque token, KlarnaPlugin.postValidation reads the token out of `collected` and looks the closure up.

import Foundation

/// Bridges ``KlarnaCoordinator``'s live `authorize()` call to ``KlarnaPlugin/postValidation(_:context:)``,
/// which runs on a fresh plugin value after `/validate` with no reference back to the coordinator
/// that prepared the widget.
actor KlarnaAuthorizationRegistry {
    static let shared = KlarnaAuthorizationRegistry()

    private var callbacks: [String: @Sendable () async throws -> Bool] = [:]

    func register(token: String, callback: @escaping @Sendable () async throws -> Bool) {
        callbacks[token] = callback
    }

    /// Reads the callback **without consuming it**. Single-use `take` semantics made a declined
    /// authorization unrecoverable: `postValidation` took the callback, called it, and threw
    /// `KlarnaAuthorizationDeclined` when the shopper declined — with the callback already gone.
    func callback(for token: String) -> (@Sendable () async throws -> Bool)? {
        callbacks[token]
    }

    /// Drops a registration whose widget never became usable, so a failed load does not leave its
    /// closure behind for the life of the process.
    func remove(_ token: String) {
        callbacks.removeValue(forKey: token)
    }
}
