import Foundation

final class SessionManager {
    private(set) var sessionId: UUID
    private(set) var sessionStart: Date
    private var lastEventAt: Date
    private let timeout: TimeInterval
    private let lock = NSLock()

    init(timeout: TimeInterval = 30 * 60) {
        self.timeout = timeout
        self.sessionId = UUID()
        self.sessionStart = Date()
        self.lastEventAt = Date()
    }

    var currentSessionId: String {
        lock.withLock { sessionId.uuidString }
    }

    var currentSessionStart: Date {
        lock.withLock { sessionStart }
    }

    /// Elapsed time in seconds since the current session started.
    var duration: TimeInterval {
        lock.withLock { Date().timeIntervalSince(sessionStart) }
    }

    /// Records that an event occurred now, for session expiry tracking.
    func recordActivity() {
        lock.withLock { lastEventAt = Date() }
    }

    /// Called on app foreground. Returns true if a new session was started due to inactivity.
    @discardableResult
    func handleForeground() -> Bool {
        lock.withLock {
            if Date().timeIntervalSince(lastEventAt) > timeout {
                startNewSession()
                return true
            }
            return false
        }
    }

    /// Starts a fresh session unconditionally (used on `reset()` and initial open).
    func reset() {
        lock.withLock { startNewSession() }
    }

    // MARK: - Private

    private func startNewSession() {
        sessionId = UUID()
        sessionStart = Date()
        lastEventAt = Date()
    }
}
