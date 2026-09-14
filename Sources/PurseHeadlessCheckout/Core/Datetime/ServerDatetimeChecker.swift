// Web: packages/sdk/src/server-datetime-checker.ts
// Same: server-offset-corrected expiry check.
// Differs: an actor rather than @Volatile fields; injectable clock and fetch for tests.

import Foundation

/// Tracks the offset between the device clock and the Purse server clock, so session-expiry checks
/// survive a wrong device clock.
public actor ServerDatetimeChecker {
    private let fetchServerTime: @Sendable () async throws -> Date
    private let clock: @Sendable () -> Date

    private var serverOffset: TimeInterval = 0
    public private(set) var synced = false

    /// - Parameter fetchServerTime: typically ``DatetimeAPIClient/datetime()``.
    public init(
        fetchServerTime: @escaping @Sendable () async throws -> Date,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetchServerTime = fetchServerTime
        self.clock = clock
    }

    /// Fetch the server time once and record the device-minus-server offset. Failures are
    /// swallowed: the checker simply stays unsynced, matching web's catch-and-log.
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

    /// Whether `expiration` has passed *for the server* (device clock corrected by the offset).
    public func isExpiredForServer(_ expiration: Date) -> Bool {
        expiration.addingTimeInterval(serverOffset) < clock()
    }
}
