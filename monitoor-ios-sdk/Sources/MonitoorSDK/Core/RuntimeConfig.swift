import Foundation

/// The live, mutable source of truth for server-controllable configuration.
///
/// Seeded from `MonitoorOptions` at startup, then optionally overwritten by a
/// `RemoteConfigResponse` fetched from `GET /v1/config`. Subsystems read from
/// this object (not the by-value `MonitoorOptions` snapshot) so the dashboard
/// can change capture behaviour at runtime without an app update.
///
/// Note: only flags that can be safely toggled at runtime live here. Installation
/// decisions (crash handlers, StoreKit observer, swizzle) are still made once at
/// bootstrap from local `MonitoorOptions` — a remote `true` cannot enable something
/// that was never installed, but a remote `false` suppresses it at the runtime gate.
final class RuntimeConfig {
    private let lock = NSLock()

    private var _captureEvents: Bool
    private var _captureScreens: Bool
    private var _captureRevenue: Bool
    private var _sampleRate: Double
    private var _retentionDays: Int

    init(options: MonitoorOptions) {
        _captureEvents  = options.captureEvents
        _captureScreens = options.captureScreens
        _captureRevenue = options.captureRevenue
        _sampleRate     = options.sampleRate
        _retentionDays  = options.retentionDays
    }

    // MARK: - Live getters

    var captureEvents:  Bool   { lock.withLock { _captureEvents } }
    var captureScreens: Bool   { lock.withLock { _captureScreens } }
    var captureRevenue: Bool   { lock.withLock { _captureRevenue } }
    var sampleRate:     Double { lock.withLock { _sampleRate } }
    var retentionDays:  Int    { lock.withLock { _retentionDays } }

    /// Derived max buffer age in seconds from the live retention value.
    var maxBufferAge: TimeInterval { TimeInterval(retentionDays) * 86_400 }

    // MARK: - Apply remote config

    func apply(_ remote: RemoteConfigResponse) {
        lock.withLock {
            _captureEvents  = remote.captureEvents
            _captureScreens = remote.captureScreens
            _captureRevenue = remote.captureRevenue
            _sampleRate     = max(0.0, min(1.0, remote.mul))
            _retentionDays  = max(1, remote.retention)
        }
    }
}
