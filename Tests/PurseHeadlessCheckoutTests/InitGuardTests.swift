import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// The guard that stops one gift card being `/init`ed twice in parallel, and stops a dead call
/// being hammered. Ported from Android's `InitGuardTest`.
struct InitGuardTests {

    /// A counter that is safe to touch from the concurrent calls under test.
    private actor Counter {
        private(set) var value = 0
        func increment() -> Int {
            value += 1
            return value
        }
    }

    private func makeGuard() async -> InitGuard {
        let guardActor = InitGuard()
        // No real backoff — the retry paths would otherwise add 1.2s per test.
        await guardActor.setSleeper { _ in }
        return guardActor
    }

    @Test func coalescesConcurrentDuplicateCalls() async throws {
        let guardActor = await makeGuard()
        let calls = Counter()

        async let first = guardActor.run(key: "k") {
            _ = await calls.increment()
            try await Task.sleep(nanoseconds: 50_000_000)
            return JSONValue.object(["ok": true])
        }
        async let second = guardActor.run(key: "k") {
            _ = await calls.increment()
            try await Task.sleep(nanoseconds: 50_000_000)
            return JSONValue.object(["ok": true])
        }

        let results = try await [first, second]
        #expect(results[0] == results[1])
        #expect(await calls.value == 1)
    }

    @Test func distinctKeysDoNotCoalesce() async throws {
        let guardActor = await makeGuard()
        let calls = Counter()

        _ = try await guardActor.run(key: "a") { .number(String(await calls.increment())) }
        _ = try await guardActor.run(key: "b") { .number(String(await calls.increment())) }

        #expect(await calls.value == 2)
    }

    /// A success is not cached — only the in-flight window coalesces, so a legitimate re-init runs.
    @Test func successesAreNotCached() async throws {
        let guardActor = await makeGuard()
        let calls = Counter()

        _ = try await guardActor.run(key: "k") { .number(String(await calls.increment())) }
        _ = try await guardActor.run(key: "k") { .number(String(await calls.increment())) }

        #expect(await calls.value == 2)
    }

    @Test func retriesTransientFailures() async throws {
        let guardActor = await makeGuard()
        let calls = Counter()

        let result = try await guardActor.run(key: "k") {
            let attempt = await calls.increment()
            if attempt < 3 { throw PaymentAPIError("flaky", status: 503) }
            return .object(["attempt": .number(String(attempt))])
        }

        #expect(result["attempt"]?.intValue == 3)
        #expect(await calls.value == InitGuard.maxAttempts)
    }

    @Test func givesUpAfterMaxAttempts() async throws {
        let guardActor = await makeGuard()
        let calls = Counter()

        await #expect(throws: PaymentAPIError.self) {
            try await guardActor.run(key: "k") {
                _ = await calls.increment()
                throw PaymentAPIError("always down", status: 500)
            }
        }
        #expect(await calls.value == InitGuard.maxAttempts)
    }

    /// Exhausting the retries on a *transient* failure must not fast-reject the next attempt.
    /// `shared` is process-wide and nothing evicts a spent entry, so treating "lost signal for two
    /// seconds" as terminal would kill that method for the life of the app process.
    @Test func aRetryableFailureThatExhaustedItsAttemptsDoesNotPoisonTheKey() async throws {
        let guardActor = await makeGuard()
        let calls = Counter()

        for _ in 0 ..< 2 {
            await #expect(throws: PaymentAPIError.self) {
                try await guardActor.run(key: "k") {
                    _ = await calls.increment()
                    throw PaymentAPIError("offline", underlying: URLError(.notConnectedToInternet))
                }
            }
        }

        // Both rounds reached the network; the key was never spent.
        #expect(await calls.value == InitGuard.maxAttempts * 2)
    }

    /// A 4xx is a definitive backend decision, so it must not be retried even once.
    @Test func doesNotRetryTerminalFailures() async throws {
        let guardActor = await makeGuard()
        let calls = Counter()

        await #expect(throws: PaymentAPIError.self) {
            try await guardActor.run(key: "k") {
                _ = await calls.increment()
                throw PaymentAPIError("refused", status: 400, errorCode: "SESSION_EXPIRED")
            }
        }
        #expect(await calls.value == 1)
    }

    /// A repeat of a call that just failed is rejected without touching the network at all.
    @Test func fastRejectsRepeatsOfASpentCall() async throws {
        let guardActor = await makeGuard()
        let calls = Counter()

        for _ in 0 ..< 2 {
            await #expect(throws: PaymentAPIError.self) {
                try await guardActor.run(key: "k") {
                    _ = await calls.increment()
                    throw PaymentAPIError("refused", status: 400)
                }
            }
        }
        #expect(await calls.value == 1)
    }

    @Test func resetClearsSpentState() async throws {
        let guardActor = await makeGuard()
        let calls = Counter()

        await #expect(throws: PaymentAPIError.self) {
            try await guardActor.run(key: "k") {
                _ = await calls.increment()
                throw PaymentAPIError("refused", status: 400)
            }
        }
        await guardActor.reset()
        _ = try? await guardActor.run(key: "k") { .number(String(await calls.increment())) }

        #expect(await calls.value == 2)
    }

    // MARK: key derivation

    /// Keyed on the amount too: an amount-driven re-init is a different call, and must never be
    /// blocked by an earlier failure at a different amount.
    @Test func keyIncludesPartnerMethodAndAmount() {
        let base: [String: JSONValue] = [
            "partner": "purse", "method": "creditcard", "amount": .number("10.00"),
        ]
        var otherAmount = base
        otherAmount["amount"] = .number("20.00")

        #expect(InitGuard.key(sessionId: "s", payload: base) != InitGuard.key(sessionId: "s", payload: otherAmount))
        #expect(InitGuard.key(sessionId: "s", payload: base) != InitGuard.key(sessionId: "other", payload: base))
        #expect(InitGuard.key(sessionId: "s", payload: base) == InitGuard.key(sessionId: "s", payload: base))
    }

    @Test func keyToleratesAMissingField() {
        #expect(InitGuard.key(sessionId: "s", payload: [:]) == "s:nil:nil:nil")
    }
}
