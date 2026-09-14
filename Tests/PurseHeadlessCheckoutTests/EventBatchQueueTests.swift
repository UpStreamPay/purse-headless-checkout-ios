import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// The batching queue behind `CheckoutEventBus` — flush on size, on byte budget, on demand, and the
/// "no processor yet" drop.
struct EventBatchQueueTests {

    @Test func flushesAsSoonAsBatchSizeIsReached() async {
        let queue = EventBatchQueue<Int>(batchSize: 3, flushAfterSeconds: 999)
        let delivered = Counter()
        await queue.setProcessor { batch in await delivered.append(batch) }

        await queue.add(1)
        await queue.add(2)
        #expect(await delivered.batches.isEmpty)
        await queue.add(3)
        #expect(await delivered.batches == [[1, 2, 3]])
    }

    @Test func flushesEarlyWhenTheByteBudgetWouldBeExceeded() async {
        // Every item "costs" 10 bytes; a 25-byte budget fits two, not three.
        let queue = EventBatchQueue<Int>(batchSize: 100, flushAfterSeconds: 999, maxBytes: 25) { _ in 10 }
        let delivered = Counter()
        await queue.setProcessor { batch in await delivered.append(batch) }

        await queue.add(1)
        await queue.add(2)
        #expect(await delivered.batches.isEmpty)
        await queue.add(3)
        #expect(await delivered.batches == [[1, 2]])
        #expect(await queue.currentQueueSize == 1)
    }

    @Test func flushDrainsWhateverIsQueuedOnDemand() async {
        let queue = EventBatchQueue<Int>(batchSize: 100, flushAfterSeconds: 999)
        let delivered = Counter()
        await queue.setProcessor { batch in await delivered.append(batch) }

        await queue.add(1)
        await queue.flush()
        #expect(await delivered.batches == [[1]])
        #expect(await queue.currentQueueSize == 0)
    }

    @Test func flushingAnEmptyQueueCallsNoProcessor() async {
        let queue = EventBatchQueue<Int>(batchSize: 100, flushAfterSeconds: 999)
        let delivered = Counter()
        await queue.setProcessor { batch in await delivered.append(batch) }
        await queue.flush()
        #expect(await delivered.batches.isEmpty)
    }

    /// Matches Android's default no-op processor: an event queued before a processor is ever wired
    /// is simply dropped on flush, not held forever.
    @Test func flushingWithNoProcessorSetDropsTheBatch() async {
        let queue = EventBatchQueue<Int>(batchSize: 1, flushAfterSeconds: 999)
        await queue.add(1)
        #expect(await queue.currentQueueSize == 0)
    }

    @Test func flushAfterTheTimeoutFiresWithoutReachingBatchSize() async throws {
        let queue = EventBatchQueue<Int>(batchSize: 100, flushAfterSeconds: 0.05)
        let delivered = Counter()
        await queue.setProcessor { batch in await delivered.append(batch) }
        await queue.add(1)

        // Poll rather than one fixed sleep — a scheduler hiccup under load must not flake this.
        for _ in 0..<50 {
            if await !delivered.batches.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(await delivered.batches == [[1]])
    }
}

private actor Counter {
    private(set) var batches: [[Int]] = []
    func append(_ batch: [Int]) { batches.append(batch) }
}
