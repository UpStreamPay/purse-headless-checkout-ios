// Web: packages/headless-checkout/src/monitoring (event bus + `postFromCode`)
// Same: batched posting, flush, envelope extras patched on `setSession`.
// Differs: **per-checkout-instance**, not a process-wide singleton. Android's bus is one singleton shared by every `PurseHeadlessCheckout` in the process, re-pointed by whichever instance called `install()` last — harmless when only one checkout exists at a time, but a real cross-instance leak if a merchant ever holds two concurrently (checkout A's events could start carrying checkout B's envelope after B's `install()` runs). Every other piece of mutable state in this SDK is already owned per-instance (`splitter`, `wallet`, …); a global bus would be the one exception, for no benefit the merchant would notice.

import Foundation

/// The analytics bus for one checkout. Every `post` lands in a batching queue (16 events / 10 s /
/// 64 KB, matching web) toward the monitoring API.
actor CheckoutEventBus {
    private let queue: EventBatchQueue<CheckoutMonitoringEvent>
    private var client: MonitoringAPIClient?
    private var instanceId = ""
    private var extras: [String: JSONValue] = [:]

    /// - Parameters mirror web's batching defaults (16 events / 10 s / 64 KB); overridable only so
    ///   tests can force a flush after one event instead of waiting on the real thresholds.
    init(batchSize: Int = 16, flushAfterSeconds: Double = 10, maxBytes: Int? = 64_000) {
        queue = EventBatchQueue(batchSize: batchSize, flushAfterSeconds: flushAfterSeconds, maxBytes: maxBytes) { event in
            (try? JSONEncoder().encode(event.toJSON()))?.count ?? 0
        }
    }

    /// Point the bus at the collector for one checkout instance — web's `getInstance(sendLogs)`.
    /// No-op events still batch even before this runs; they are simply dropped on flush, since
    /// there is nowhere to send them yet (matches `EventBatchQueue`'s no-processor behaviour).
    func install(client: MonitoringAPIClient, instanceId: String) async {
        self.client = client
        self.instanceId = instanceId
        await queue.setProcessor { [weak self] batch in
            guard let self else { return }
            await self.send(batch)
        }
    }

    /// Merge context onto every future message — web's `patchExtrasData`.
    func patchExtras(
        entityId: String? = nil,
        paymentSessionId: String? = nil,
        walletSessionId: String? = nil,
        version: String? = nil,
        wrapper: String? = nil
    ) {
        if let entityId { extras["entityId"] = .string(entityId) }
        if let paymentSessionId { extras["paymentSessionId"] = .string(paymentSessionId) }
        if let walletSessionId { extras["walletSessionId"] = .string(walletSessionId) }
        if let version { extras["version"] = .string(version) }
        if let wrapper { extras["wrapper"] = .string(wrapper) }
    }

    func post(_ code: CheckoutEventCode, _ type: EventLevel = .info, _ payload: JSONValue? = nil) async {
        await queue.add(CheckoutMonitoringEvent(code: code, type: type, payload: payload))
    }

    /// Drain the batch queue now — web's `purge()`, for teardown / app-background.
    func flush() async {
        await queue.flush()
    }

    private func send(_ batch: [CheckoutMonitoringEvent]) async {
        guard let client else { return }
        await client.sendLogs(batch.map { $0.toJSON() }, instanceId: instanceId, extras: extras)
    }
}
