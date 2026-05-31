import Foundation

final class EventCapture {
    private let buffer: LocalBuffer
    private let sessionManager: SessionManager
    private let identity: UserIdentity
    private let deviceIdentity: DeviceIdentity
    private let deviceInfo: DeviceInfo
    private let flushEngine: FlushEngine
    private let options: MonitoorOptions
    private let flushBatchSize: Int

    private var timers: [String: Date] = [:]
    private let timersLock = NSLock()

    init(
        buffer: LocalBuffer,
        sessionManager: SessionManager,
        identity: UserIdentity,
        deviceIdentity: DeviceIdentity,
        deviceInfo: DeviceInfo,
        flushEngine: FlushEngine,
        options: MonitoorOptions
    ) {
        self.buffer         = buffer
        self.sessionManager = sessionManager
        self.identity       = identity
        self.deviceIdentity = deviceIdentity
        self.deviceInfo     = deviceInfo
        self.flushEngine    = flushEngine
        self.options        = options
        self.flushBatchSize = options.flushBatchSize
    }

    func track(_ name: String, properties: [String: Any]) {
        var mergedProperties = properties
        // Attach duration for timed events.
        if let start = consumeTimer(name) {
            mergedProperties["$duration"] = Date().timeIntervalSince(start)
        }
        enqueue(name: name, type: "event", properties: mergedProperties)
    }

    func startTimer(_ name: String) {
        timersLock.withLock { timers[name] = Date() }
    }

    // MARK: - Internal helpers

    func enqueue(name: String, type: String, properties: [String: Any]) {
        // Apply client-side sampling. System lifecycle events ($ prefix) are never sampled out.
        if !name.hasPrefix("$"), options.sampleRate < 1.0 {
            guard Double.random(in: 0..<1) < options.sampleRate else { return }
        }

        sessionManager.recordActivity()

        let occurredAt = ISO8601DateFormatter.monitoor.string(from: Date())
        let idempotencyKey = "\(deviceIdentity.deviceId)-\(sessionManager.currentSessionId)-\(occurredAt)"

        let event = PendingEvent(
            type: type,
            name: name,
            sessionId: sessionManager.currentSessionId,
            deviceId: deviceIdentity.deviceId,
            userIdHash: identity.userIdHash,
            idempotencyKey: idempotencyKey,
            occurredAt: occurredAt,
            properties: properties.isEmpty ? nil : properties.toAnyCodable(),
            context: deviceInfo.asEventContext()
        )

        guard let data = try? JSONEncoder().encode(event) else { return }
        try? buffer.enqueue(payload: data, type: .event)

        // Flush immediately if the batch is full.
        if let count = try? buffer.pendingCount(), count >= flushBatchSize {
            flushEngine.flush()
        }
    }

    private func consumeTimer(_ name: String) -> Date? {
        timersLock.withLock {
            let start = timers[name]
            timers.removeValue(forKey: name)
            return start
        }
    }
}

extension ISO8601DateFormatter {
    static let monitoor: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
