// Web: none — web's plugin calls Klarna's JS client directly from its own closure scope.
// Same: the seam Android's `PartnerUiContext.collected[COLLECTED_AUTHORIZE]` serves.
// Differs: `collected` is wire-safe `JSONValue` only, so the closure cannot travel through it as Android's untyped map allows — the coordinator registers it here under an opaque token that does.

import Foundation

/// Bridges ``KlarnaCoordinator``'s live `authorize()` to ``KlarnaPlugin/postValidation(_:context:)``,
/// which runs on a fresh plugin value with no reference back to the coordinator.
actor KlarnaAuthorizationRegistry {
    static let shared = KlarnaAuthorizationRegistry()

    private var callbacks: [String: @Sendable () async throws -> Bool] = [:]

    func register(token: String, callback: @escaping @Sendable () async throws -> Bool) {
        callbacks[token] = callback
    }

    /// Reads the callback **without consuming it**: a decline must stay retryable, and single-use
    /// semantics would leave the second attempt with nothing to call.
    func callback(for token: String) -> (@Sendable () async throws -> Bool)? {
        callbacks[token]
    }

    /// Drops a registration whose widget never became usable, so a failed load leaks no closure.
    func remove(_ token: String) {
        callbacks.removeValue(forKey: token)
    }
}
