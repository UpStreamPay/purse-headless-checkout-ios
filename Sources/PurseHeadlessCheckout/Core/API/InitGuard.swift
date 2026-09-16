// Web: packages/partner-ui/src/commons/PartnerUI/initGuard.ts
// Same: coalesce duplicate /init calls, retry transient failures, fast-reject a call that just failed.
// Differs: an actor rather than a synchronized object; waiters await a Task instead of a latch.

import Foundation

/// Guards `/init` calls at the network boundary — the Swift port of web partner-ui's `initGuard`: -
/// **coalesces** concurrent duplicate calls (same key → all callers share one in-flight request); -
/// **retries** transient failures (``PaymentAPIError/isRetryable``: no HTTP status, or ≥ 500) up to
public actor InitGuard {

    public static let shared = InitGuard()

    public static let maxAttempts = 3
    public static let backoffNanoseconds: [UInt64] = [300_000_000, 900_000_000]
    public static let maxTrackedKeys = 100

    private enum Entry {
        case inFlight(Task<JSONValue, any Error>)
        case spent(any Error)
    }

    /// Insertion order is tracked separately so over-capacity eviction can drop the oldest key —
    /// a Swift `Dictionary` has no insertion order, unlike the `LinkedHashMap` Android uses.
    private var guarded: [String: Entry] = [:]
    private var insertionOrder: [String] = []

    /// Test hook — overridable so retry backoff does not slow the suite down.
    var sleeper: @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }

    public init() {}

    public nonisolated static func key(sessionId: String, payload: [String: JSONValue]) -> String {
        let part: (String) -> String = { name in
            guard let value = payload[name] else { return "nil" }
            switch value {
            case let .string(text): return text
            case let .number(text): return text
            default: return "\(value)"
            }
        }
        return "\(sessionId):\(part("partner")):\(part("method")):\(part("amount"))"
    }

    /// Run `call` under the guard for `key`.
    public func run(key: String, call: @escaping @Sendable () async throws -> JSONValue) async throws -> JSONValue {
        switch guarded[key] {
        case let .spent(error):
            throw error
        case let .inFlight(task):
            return try await task.value
        case nil:
            break
        }

        let task = Task<JSONValue, any Error> { [sleeper] in
            var attempts = 0
            while true {
                do {
                    return try await call()
                } catch {
                    attempts += 1
                    let retryable = (error as? PaymentAPIError)?.isRetryable ?? true
                    guard retryable, attempts < Self.maxAttempts else { throw error }
                    // Clamped to the last entry so `backoffNanoseconds` can be shorter than
                    // `maxAttempts - 1` without indexing out of bounds.
                    let index = min(attempts - 1, Self.backoffNanoseconds.count - 1)
                    try await sleeper(Self.backoffNanoseconds[index])
                }
            }
        }

        store(.inFlight(task), for: key)

        do {
            let result = try await task.value
            remove(key)
            return result
        } catch {
            // Fast-rejection is for a **terminal** failure only — that is what this type's own doc
            // promises, and what a 4xx means.
            if (error as? PaymentAPIError)?.isRetryable == false {
                store(.spent(error), for: key)
            } else {
                remove(key)
            }
            throw error
        }
    }

    private func store(_ entry: Entry, for key: String) {
        if guarded[key] == nil {
            insertionOrder.append(key)
        }
        guarded[key] = entry
        evictOldestIfOverCapacity()
    }

    private func remove(_ key: String) {
        guarded[key] = nil
        insertionOrder.removeAll { $0 == key }
    }

    private func evictOldestIfOverCapacity() {
        while insertionOrder.count > Self.maxTrackedKeys {
            let oldest = insertionOrder.removeFirst()
            guarded[oldest] = nil
        }
    }

    /// Test-only: clears all tracked guard state between test cases.
    public func reset() {
        guarded.removeAll()
        insertionOrder.removeAll()
    }

    /// Test-only: replaces the backoff sleeper.
    func setSleeper(_ sleeper: @escaping @Sendable (UInt64) async throws -> Void) {
        self.sleeper = sleeper
    }
}
