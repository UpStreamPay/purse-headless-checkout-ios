// Web: packages/headless-checkout/src/monitoring (event bus + `postFromCode`)
// Same: batched posting, flush, envelope extras patched on `setSession`.
// Differs: per-checkout-instance, not Android's process-wide singleton — that one is re-pointed by whichever instance called `install()` last, so two concurrent checkouts cross their envelopes.

import Foundation

/// The analytics bus for one checkout. Batches 16 events / 10 s / 64 KB, matching web.
actor CheckoutEventBus {
    private let queue: EventBatchQueue<CheckoutMonitoringEvent>
    private var client: MonitoringAPIClient?
    private var instanceId = ""
    private var extras: [String: JSONValue] = [:]

    /// Overridable only so tests can force a flush after one event.
    init(batchSize: Int = 16, flushAfterSeconds: Double = 10, maxBytes: Int? = 64_000) {
        queue = EventBatchQueue(batchSize: batchSize, flushAfterSeconds: flushAfterSeconds, maxBytes: maxBytes) { event in
            (try? JSONEncoder().encode(event.toJSON()))?.count ?? 0
        }
    }

    /// Web's `getInstance(sendLogs)`. Events posted before this runs are dropped on flush.
    func install(client: MonitoringAPIClient, instanceId: String) async {
        self.client = client
        self.instanceId = instanceId
        await queue.setProcessor { [weak self] batch in
            guard let self else { return }
            await self.send(batch)
        }
    }

    /// Web's `patchExtrasData`.
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

    /// Web's `purge()`, for teardown / app-background.
    func flush() async {
        await queue.flush()
    }

    private func send(_ batch: [CheckoutMonitoringEvent]) async {
        guard let client else { return }
        await client.sendLogs(batch.map { $0.toJSON() }, instanceId: instanceId, extras: extras)
    }
}
