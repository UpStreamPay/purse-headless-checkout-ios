// Web: packages/common queue behind the event bus (`SimpleQueue.ts`)
// Same: batch and flush.
// Differs: an actor rather than a lock; the pending-flush timer is a cancellable `Task`.

import Foundation

/// Flushes at `batchSize` items, `flushAfterSeconds` after the first queued item, or early when the
/// queued payload would exceed `maxBytes`.
actor EventBatchQueue<Item: Sendable> {
    private let batchSize: Int
    private let flushAfterNanoseconds: UInt64
    private let maxBytes: Int?
    private let byteSizer: @Sendable (Item) -> Int

    private var processor: (@Sendable ([Item]) async -> Void)?
    private var items: [Item] = []
    private var queuedBytes = 0
    private var pendingFlush: Task<Void, Never>?

    init(
        batchSize: Int,
        flushAfterSeconds: Double = 10,
        maxBytes: Int? = nil,
        byteSizer: @escaping @Sendable (Item) -> Int = { _ in 0 }
    ) {
        precondition(batchSize > 0, "EventBatchQueue batch size must be positive")
        self.batchSize = batchSize
        self.flushAfterNanoseconds = UInt64(max(0, flushAfterSeconds) * 1_000_000_000)
        self.maxBytes = maxBytes
        self.byteSizer = byteSizer
    }

    func setProcessor(_ processor: @escaping @Sendable ([Item]) async -> Void) {
        self.processor = processor
    }

    func add(_ item: Item) async {
        let size = byteSizer(item)
        if let maxBytes, queuedBytes + size > maxBytes {
            await flushNow()
        }
        items.append(item)
        queuedBytes += size
        if items.count >= batchSize {
            await flushNow()
            return
        }
        if pendingFlush == nil {
            pendingFlush = Task { [flushAfterNanoseconds] in
                try? await Task.sleep(nanoseconds: flushAfterNanoseconds)
                guard !Task.isCancelled else { return }
                await self.timerFired()
            }
        }
    }

    func flush() async {
        await flushNow()
    }

    /// The timer cannot call ``flush()``: ``flushNow()`` cancels `pendingFlush`, which on this path
    /// is the task currently executing.
    private func timerFired() async {
        pendingFlush = nil
        await flushNow()
    }

    var currentQueueSize: Int { items.count }

    private func flushNow() async {
        pendingFlush?.cancel()
        pendingFlush = nil
        guard !items.isEmpty else { return }
        guard let processor else {
            // No processor wired yet: the caller always installs one before the first `post()`.
            items.removeAll()
            queuedBytes = 0
            return
        }
        while !items.isEmpty {
            let batch = Array(items.prefix(batchSize))
            items.removeFirst(batch.count)
            queuedBytes = max(0, queuedBytes - batch.reduce(0) { $0 + byteSizer($1) })
            await processor(batch)
        }
    }
}
