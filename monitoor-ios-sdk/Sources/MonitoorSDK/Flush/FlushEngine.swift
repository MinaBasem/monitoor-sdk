import Foundation
import Network

final class FlushEngine {
    private let buffer: LocalBuffer
    private let httpClient: HTTPClient
    private let apiKey: String
    private let options: MonitoorOptions

    private var flushTimer: Timer?
    private var networkMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "io.monitoor.network")
    private let flushQueue   = DispatchQueue(label: "io.monitoor.flush", qos: .utility)

    private var isFlushing = false
    private let flushLock = NSLock()

    init(buffer: LocalBuffer, httpClient: HTTPClient, apiKey: String, options: MonitoorOptions) {
        self.buffer     = buffer
        self.httpClient = httpClient
        self.apiKey     = apiKey
        self.options    = options
    }

    // MARK: - Lifecycle

    func start() {
        scheduleTimer()
        startNetworkMonitor()
        registerAppLifecycleObservers()
        pruneExpiredEvents()
    }

    func stop() {
        flushTimer?.invalidate()
        flushTimer = nil
        networkMonitor?.cancel()
        networkMonitor = nil
    }

    // MARK: - Flush entry point

    func flush(completion: (() -> Void)? = nil) {
        flushQueue.async { [weak self] in
            self?.flushLock.withLock {
                guard let self, !self.isFlushing else {
                    completion?()
                    return
                }
                self.isFlushing = true
            }
            self?.drainBuffer(attempt: 0, completion: {
                self?.flushLock.withLock { self?.isFlushing = false }
                completion?()
            })
        }
    }

    // MARK: - Drain loop

    private func drainBuffer(attempt: Int, completion: (() -> Void)?) {
        Task {
            do {
                let rows = try buffer.dequeue(limit: options.flushBatchSize)
                guard !rows.isEmpty else {
                    completion?()
                    return
                }

                let events = rows.compactMap { row -> WireEvent? in
                    guard let event = try? JSONDecoder().decode(PendingEvent.self, from: row.payload) else { return nil }
                    return WireEvent(
                        type: event.type,
                        name: event.name,
                        sessionId: event.sessionId,
                        deviceId: event.deviceId,
                        userIdHash: event.userIdHash,
                        idempotencyKey: event.idempotencyKey,
                        occurredAt: event.occurredAt,
                        properties: event.properties,
                        context: event.context
                    )
                }
                let outbound = OutboundBatch(events: events, rowIds: rows.map { $0.rowId })

                let result = await httpClient.send(
                    batch: outbound,
                    apiKey: apiKey,
                    ingestURL: options.ingestURL,
                    attempt: attempt
                )

                switch result {
                case .success(let response):
                    let rejectedIndexes = response.errors.map { $0.index }
                    let successIds      = outbound.rowIdsExcluding(indexes: rejectedIndexes)
                    let rejectedIds     = outbound.rowIdsAt(indexes: rejectedIndexes)
                    try? buffer.markSent(ids: successIds)
                    try? buffer.markFailed(ids: rejectedIds)
                    drainBuffer(attempt: 0, completion: completion)

                case .rateLimited(let retryAfter):
                    scheduleRetry(after: retryAfter)
                    completion?()

                case .serverError(let currentAttempt):
                    let delay = min(pow(2.0, Double(currentAttempt)), 300.0)
                    try? buffer.incrementAttempts(ids: outbound.rowIds)
                    scheduleRetry(after: delay)
                    completion?()

                case .clientError:
                    try? buffer.markFailed(ids: outbound.rowIds)
                    drainBuffer(attempt: 0, completion: completion)
                }
            } catch {
                completion?()
            }
        }
    }

    // MARK: - Setup helpers

    private func scheduleTimer() {
        flushTimer = Timer.scheduledTimer(withTimeInterval: options.flushInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Only POST on the timer tick if there are pending events in the buffer.
            // An empty timer tick produces no HTTP request.
            if (try? self.buffer.pendingCount()) ?? 0 > 0 {
                self.flush()
            }
        }
    }

    private func startNetworkMonitor() {
        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            guard let self, path.status == .satisfied else { return }
            // Only flush on network restore if there are events waiting to be sent.
            if (try? self.buffer.pendingCount()) ?? 0 > 0 {
                self.flush()
            }
        }
        networkMonitor?.start(queue: monitorQueue)
    }

    private func registerAppLifecycleObservers() {
        let nc = NotificationCenter.default

        nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.flushOnBackground()
        }

        nc.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.flushSynchronously()
        }
    }

    private func flushOnBackground() {
        let taskId = UIApplication.shared.beginBackgroundTask(withName: "monitoor.flush") {
            // Expiry handler — nothing to clean up.
        }
        flush {
            UIApplication.shared.endBackgroundTask(taskId)
        }
    }

    private func flushSynchronously() {
        let sema = DispatchSemaphore(value: 0)
        flush { sema.signal() }
        sema.wait(timeout: .now() + 3)
    }

    private func scheduleRetry(after delay: TimeInterval) {
        flushQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.flush()
        }
    }

    private func pruneExpiredEvents() {
        try? buffer.pruneExpired(maxAge: options.maxBufferAge)
    }
}

// Needed to reference UIApplication inside the SDK target.
import UIKit
