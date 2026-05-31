import Foundation

final class SessionManager {
    private(set) var sessionId: UUID
    private(set) var sessionStart: Date
    private var lastEventAt: Date
    private let timeout: TimeInterval
    private let lock = NSLock()

    // Accumulated foreground-only seconds from previous foreground periods
    // within this session (background time is excluded).
    private var accumulatedForegroundTime: TimeInterval = 0

    // When the app most recently entered the foreground for this session.
    private var foregroundEnteredAt: Date = Date()

    init(timeout: TimeInterval = 30 * 60) {
        self.timeout = timeout
        self.sessionId = UUID()
        self.sessionStart = Date()
        self.lastEventAt = Date()
        self.foregroundEnteredAt = Date()
    }

    var currentSessionId: String {
        lock.withLock { sessionId.uuidString }
    }

    var currentSessionStart: Date {
        lock.withLock { sessionStart }
    }

    /// Active foreground time in seconds for this session.
    /// Background time is excluded — this measures how long the user
    /// actually had the app open on screen, not wall-clock time.
    var duration: TimeInterval {
        lock.withLock {
            accumulatedForegroundTime + Date().timeIntervalSince(foregroundEnteredAt)
        }
    }

    /// Records that an event occurred now, for session expiry tracking.
    func recordActivity() {
        lock.withLock { lastEventAt = Date() }
    }

    /// Called when the app enters the foreground.
    /// Returns true if a new session was started due to inactivity.
    @discardableResult
    func handleForeground() -> Bool {
        lock.withLock {
            if Date().timeIntervalSince(lastEventAt) > timeout {
                startNewSession()
                return true
            }
            // Resume accumulating foreground time for the existing session.
            foregroundEnteredAt = Date()
            return false
        }
    }

    /// Called when the app enters the background.
    /// Freezes the foreground time accumulator until the next foreground.
    func handleBackground() {
        lock.withLock {
            accumulatedForegroundTime += Date().timeIntervalSince(foregroundEnteredAt)
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
    }
}
