import Foundation
import CryptoKit

final class UserIdentity {
    private var _userIdHash: String?
    private var _properties: [String: Any] = [:]
    private let lock = NSLock()

    var userIdHash: String? {
        lock.withLock { _userIdHash }
    }

    var properties: [String: Any] {
        lock.withLock { _properties }
    }

    /// SHA-256 hashes `userId` before storing. Monitoor never sees the plaintext ID.
    func setUserId(_ userId: String) {
        let hash = SHA256.hash(data: Data(userId.utf8))
        let hex = hash.compactMap { String(format: "%02x", $0) }.joined()
        lock.withLock { _userIdHash = hex }
    }

    func setProperties(_ props: [String: Any]) {
        lock.withLock { _properties.merge(props) { _, new in new } }
    }

    func reset() {
        lock.withLock {
            _userIdHash = nil
            _properties = [:]
        }
    }
}
