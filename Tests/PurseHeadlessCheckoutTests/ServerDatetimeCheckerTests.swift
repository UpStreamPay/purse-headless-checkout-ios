import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// Expiry is checked against server time, not the device clock — a shopper with a wrong clock must
/// not be told their session expired, and must not be allowed to submit one that has.
struct ServerDatetimeCheckerTests {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func usesTheLocalClockUntilSynced() async {
        let checker = ServerDatetimeChecker(
            fetchServerTime: { throw PaymentAPIError("offline") },
            clock: { self.now }
        )

        #expect(await !checker.synced)
        #expect(await checker.isExpiredForServer(now.addingTimeInterval(-1)))
        #expect(await !checker.isExpiredForServer(now.addingTimeInterval(1)))
    }

    /// A failed sync must never block a payment — it leaves the checker unsynced and moves on.
    @Test func aFailedSyncIsSwallowed() async {
        let checker = ServerDatetimeChecker(
            fetchServerTime: { throw PaymentAPIError("offline") },
            clock: { self.now }
        )
        await checker.sync()
        #expect(await !checker.synced)
    }

    /// Device clock an hour ahead: a session expiring in ten minutes of *server* time is not
    /// expired, even though the device thinks that moment has passed.
    @Test func correctsAFastDeviceClock() async {
        let serverNow = now.addingTimeInterval(-3600)
        let checker = ServerDatetimeChecker(fetchServerTime: { serverNow }, clock: { self.now })
        await checker.sync()

        #expect(await checker.synced)
        #expect(await !checker.isExpiredForServer(serverNow.addingTimeInterval(600)))
        #expect(await checker.isExpiredForServer(serverNow.addingTimeInterval(-600)))
    }

    /// Device clock an hour behind: a session that really has expired must still read as expired.
    @Test func correctsASlowDeviceClock() async {
        let serverNow = now.addingTimeInterval(3600)
        let checker = ServerDatetimeChecker(fetchServerTime: { serverNow }, clock: { self.now })
        await checker.sync()

        #expect(await checker.isExpiredForServer(serverNow.addingTimeInterval(-600)))
        #expect(await !checker.isExpiredForServer(serverNow.addingTimeInterval(600)))
    }

    @Test func syncsOnlyOnce() async {
        let calls = CallCounter()
        let checker = ServerDatetimeChecker(
            fetchServerTime: { await calls.increment(); return self.now },
            clock: { self.now }
        )

        await checker.sync()
        await checker.sync()

        #expect(await calls.value == 1)
    }

    private actor CallCounter {
        private(set) var value = 0
        func increment() { value += 1 }
    }
}
