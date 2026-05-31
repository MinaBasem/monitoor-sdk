import Foundation

final class SessionManager {
    private(set) var sessionId: UUID
    private(set) var sessionStart: Date
    private var lastEventAt: Date
    private let timeout: TimeInterval
    private let lock = NSLock()

    // Foreground-only time accumulated from completed foreground periods.
    private var accumulatedForegroundTime: TimeInterval = 0
    // When the current foreground period started (only valid while isInForeground = true).
    private var foregroundEnteredAt: Date = Date()
    // Whether the app is currently in the foreground.
    private var isInForeground: Bool = true

    init(timeout: TimeInterval = 30 * 60) {
        self.timeout = timeout
        self.sessionId = UUID()
        self.sessionStart = Date()
        self.lastEventAt = Date()
        self.foregroundEnteredAt = Date()
        self.isInForeground = true
    }

    var currentSessionId: String {
        lock.withLock { sessionId.uuidString }
    }

    var currentSessionStart: Date {
        lock.withLock { sessionStart }
    }

    /// Active foreground time in seconds for this session.
    /// Only counts time the app was actually on screen — background time is excluded.
    var duration: TimeInterval {
        lock.withLock {
            if isInForeground {
                return accumulatedForegroundTime + Date().timeIntervalSince(foregroundEnteredAt)
            } else {
                return accumulatedForegroundTime
            }
        }
    }

    /// Records that an event occurred now, for session expiry tracking.
    func recordActivity() {
        lock.withLock { lastEventAt = Date() }
    }

    /// Call when the app enters the foreground.
    /// Returns true if a new session was started due to inactivity.
    @discardableResult
    func handleForeground() -> Bool {
        lock.withLock {
            if Date().timeIntervalSince(lastEventAt) > timeout {
                startNewSession()
                return true
            }
            foregroundEnteredAt = Date()
            isInForeground = true
            return false
        }
    }

    /// Call when the app enters the background.
    /// Freezes the foreground timer so background time is never counted.
    func handleBackground() {
        lock.withLock {
            guard isInForeground else { return }
            accumulatedForegroundTime += Date().timeIntervalSince(foregroundEnteredAt)
            isInForeground = false
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
        accumulatedForegroundTime = 0
        foregroundEnteredAt = Date()
        isInForeground = true
    }
}
