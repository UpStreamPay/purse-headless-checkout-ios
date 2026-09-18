// Web: packages/sdk/src/server-datetime-checker.ts
// Same: server-offset-corrected expiry check.
// Differs: an actor rather than @Volatile fields; injectable clock and fetch for tests.

import Foundation

/// Device-to-server clock offset, so session-expiry checks survive a wrong device clock.
public actor ServerDatetimeChecker {
    private let fetchServerTime: @Sendable () async throws -> Date
    private let clock: @Sendable () -> Date

    private var serverOffset: TimeInterval = 0
    public private(set) var synced = false

    public init(
        fetchServerTime: @escaping @Sendable () async throws -> Date,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetchServerTime = fetchServerTime
        self.clock = clock
    }

    /// Failures are swallowed on purpose — a payment must never be blocked because a clock-sync
    /// call timed out. Matches web's catch-and-log.
    public func sync() async {
        guard !synced else { return }
        do {
            let serverNow = try await fetchServerTime()
            serverOffset = clock().timeIntervalSince(serverNow)
            synced = true
        } catch {
            // Stay unsynced; expiry checks use the local clock until a later sync succeeds.
        }
    }

    /// Whether `expiration` has passed *for the server*.
    public func isExpiredForServer(_ expiration: Date) -> Bool {
        expiration.addingTimeInterval(serverOffset) < clock()
    }
}
