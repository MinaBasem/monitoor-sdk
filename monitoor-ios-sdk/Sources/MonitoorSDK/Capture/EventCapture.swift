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
    private let runtimeConfig: RuntimeConfig
    private let superProperties: SuperProperties
    private let consent: ConsentManager

    private var timers: [String: Date] = [:]
    private let timersLock = NSLock()

    init(
        buffer: LocalBuffer,
        sessionManager: SessionManager,
        identity: UserIdentity,
        deviceIdentity: DeviceIdentity,
        deviceInfo: DeviceInfo,
        flushEngine: FlushEngine,
        options: MonitoorOptions,
        runtimeConfig: RuntimeConfig,
        superProperties: SuperProperties,
        consent: ConsentManager
    ) {
        self.buffer          = buffer
        self.sessionManager  = sessionManager
        self.identity        = identity
        self.deviceIdentity  = deviceIdentity
        self.deviceInfo      = deviceInfo
        self.flushEngine     = flushEngine
        self.options         = options
        self.flushBatchSize  = options.flushBatchSize
        self.runtimeConfig   = runtimeConfig
        self.superProperties = superProperties
        self.consent         = consent
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
        // Consent gate — the single choke point. When opted out, nothing is captured.
        guard !consent.isOptedOut else { return }

        // Apply client-side sampling using the live config. System lifecycle events
        // ($ prefix) are never sampled out.
        if !name.hasPrefix("$"), runtimeConfig.sampleRate < 1.0 {
            guard Double.random(in: 0..<1) < runtimeConfig.sampleRate else { return }
        }

        sessionManager.recordActivity()

        // Merge super properties (global) with event-specific properties.
        // Event-specific keys win on conflict.
        var mergedProperties = superProperties.all()
        mergedProperties.merge(properties) { _, new in new }

        let occurredAt = ISO8601DateFormatter.monitoor.string(from: Date())
        // UUID suffix guarantees uniqueness even when two events occur within the same millisecond.
        // The key is stored in the buffer, so retried batches resend the same key and the
        // server's ON CONFLICT DO NOTHING prevents duplicates without losing events.
        let idempotencyKey = "\(deviceIdentity.deviceId)-\(UUID().uuidString)"

        let event = PendingEvent(
            type: type,
            name: name,
            sessionId: sessionManager.currentSessionId,
            deviceId: deviceIdentity.deviceId,
            userIdHash: identity.userIdHash,
            idempotencyKey: idempotencyKey,
            occurredAt: occurredAt,
            properties: mergedProperties.isEmpty ? nil : mergedProperties.toAnyCodable(),
            context: deviceInfo.asEventContext()
        )

        guard let data = try? JSONEncoder().encode(event) else { return }
        try? buffer.enqueue(payload: data, type: .event)

        // Flush immediately if the batch is full.
        if let count = try? buffer.pendingCount() {
            MonitoorSDK.log("[enqueue] '\(name)' — pending=\(count) batchSize=\(flushBatchSize)")
            if count >= flushBatchSize {
                MonitoorSDK.log("[flush] BATCH FULL (\(count) events) — flushing now")
                flushEngine.flush()
            }
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
