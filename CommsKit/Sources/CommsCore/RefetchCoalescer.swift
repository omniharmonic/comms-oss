import Foundation

/// Coalesces "refetch thread X" requests so an event burst (a busy group, or a
/// Last-Event-ID replay after the laptop wakes) cannot drain the server's shared
/// 600-requests-per-minute `comms` bucket.
///
/// - Requests are collected for `delay` (≈ 300 ms) after the first one, then flushed: each
///   thread id is fetched once however many requests named it.
/// - At most one fetch per thread is in flight. A request for a thread whose fetch is in
///   flight marks it dirty; it is fetched once more (after `delay`) when the first finishes,
///   so the last event is never lost.
/// - At most `maxConcurrent` fetches run at once; the rest queue.
/// - A flush naming `batchThreshold` or more threads (a reconnect replay) calls `batch`
///   once instead (the list store reloads its first page) when one is given.
@MainActor
public final class RefetchCoalescer {
    public let delay: Duration
    public let maxConcurrent: Int
    public let batchThreshold: Int

    private let fetch: @MainActor (String) async -> Void
    private let batch: (@MainActor ([String]) async -> Void)?

    /// Collected since the last flush, in arrival order.
    private var pending: [String] = []
    /// Flushed, waiting for a concurrency slot.
    private var queue: [String] = []
    private var inFlight: Set<String> = []
    private var dirty: Set<String> = []
    private var batchRunning = false
    private var timer: Task<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(
        delay: Duration = .milliseconds(300),
        maxConcurrent: Int = 4,
        batchThreshold: Int = 10,
        fetch: @escaping @MainActor (String) async -> Void,
        batch: (@MainActor ([String]) async -> Void)? = nil
    ) {
        self.delay = delay
        self.maxConcurrent = max(1, maxConcurrent)
        self.batchThreshold = max(2, batchThreshold)
        self.fetch = fetch
        self.batch = batch
    }

    /// Ask for `id` to be refetched (soon, once).
    public func request(_ id: String) {
        if inFlight.contains(id) || batchRunning {
            dirty.insert(id)
            return
        }
        guard !pending.contains(id), !queue.contains(id) else { return }
        pending.append(id)
        schedule()
    }

    /// Returns when nothing is pending, queued or in flight.
    public func idle() async {
        if isIdle { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    public var isIdle: Bool { pending.isEmpty && queue.isEmpty && inFlight.isEmpty && dirty.isEmpty && timer == nil && !batchRunning }

    private func schedule() {
        guard timer == nil, !pending.isEmpty else { return }
        timer = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            self?.flush()
        }
    }

    private func flush() {
        timer = nil
        let ids = pending
        pending.removeAll()
        if let batch, ids.count >= batchThreshold, inFlight.isEmpty {
            batchRunning = true
            Task {
                await batch(ids)
                self.batchRunning = false
                // Requests that arrived during the batch are fetched individually.
                let again = self.dirty
                self.dirty.removeAll()
                for id in again where !self.pending.contains(id) { self.pending.append(id) }
                self.schedule()
                self.settle()
            }
            return
        }
        queue.append(contentsOf: ids.filter { !queue.contains($0) })
        startQueued()
        settle()
    }

    private func startQueued() {
        while inFlight.count < maxConcurrent, !queue.isEmpty {
            let id = queue.removeFirst()
            inFlight.insert(id)
            Task {
                await fetch(id)
                self.finished(id)
            }
        }
    }

    private func finished(_ id: String) {
        inFlight.remove(id)
        if dirty.remove(id) != nil, !pending.contains(id) {
            pending.append(id)
            schedule()
        }
        startQueued()
        settle()
    }

    private func settle() {
        guard isIdle, !waiters.isEmpty else { return }
        let ready = waiters
        waiters.removeAll()
        for w in ready { w.resume() }
    }
}
