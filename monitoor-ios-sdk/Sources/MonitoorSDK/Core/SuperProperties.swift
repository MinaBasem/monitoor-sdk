import Foundation

/// Global key/value properties that are merged into every captured event.
///
/// Use for attributes that should accompany all events without repeating them
/// on each `track()` call (e.g. app tier, experiment cohort, build channel).
/// Persisted to UserDefaults so they survive app launches.
///
/// Values must be plist- and JSON-safe (`String`, `Int`, `Double`, `Bool`) to
/// match what `AnyCodable` can encode on the wire.
final class SuperProperties {
    private let defaultsKey = "io.monitoor.superProperties"
    private let store: UserDefaults
    private let lock = NSLock()
    private var properties: [String: Any]

    init(store: UserDefaults = .standard) {
        self.store = store
        self.properties = store.dictionary(forKey: defaultsKey) ?? [:]
    }

    /// Merges `props` into the existing set. Existing keys are overwritten.
    func register(_ props: [String: Any]) {
        lock.withLock {
            properties.merge(props) { _, new in new }
            persist()
        }
    }

    /// Removes a single super property by key.
    func unregister(_ key: String) {
        lock.withLock {
            properties.removeValue(forKey: key)
            persist()
        }
    }

    /// Removes all super properties.
    func clear() {
        lock.withLock {
            properties = [:]
            persist()
        }
    }

    /// A snapshot of the current super properties.
    func all() -> [String: Any] {
        lock.withLock { properties }
    }

    // MARK: - Private

    /// Must be called while holding `lock`.
    private func persist() {
        store.set(properties, forKey: defaultsKey)
    }
}
