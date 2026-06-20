import Foundation

/// Tracks whether the user has opted out of analytics collection.
///
/// When opted out: no events are captured, nothing is flushed, and the local
/// buffer is purged. The choice is persisted to UserDefaults and read at launch
/// so it survives relaunches — required for GDPR / App Store consent flows.
final class ConsentManager {
    private let defaultsKey = "io.monitoor.optedOut"
    private let store: UserDefaults
    private let lock = NSLock()
    private var optedOut: Bool

    init(store: UserDefaults = .standard) {
        self.store = store
        self.optedOut = store.bool(forKey: defaultsKey)
    }

    var isOptedOut: Bool {
        lock.withLock { optedOut }
    }

    func optOut() {
        lock.withLock {
            optedOut = true
            store.set(true, forKey: defaultsKey)
        }
    }

    func optIn() {
        lock.withLock {
            optedOut = false
            store.set(false, forKey: defaultsKey)
        }
    }
}
