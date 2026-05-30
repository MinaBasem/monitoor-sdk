import Foundation
import Security

final class DeviceIdentity {
    private static let service = "io.monitoor.sdk"
    private static let account = "device_id"

    let deviceId: String

    init() {
        if let existing = Self.read() {
            deviceId = existing
        } else {
            let new = UUID().uuidString
            Self.write(new)
            deviceId = new
        }
    }

    /// Clears the stored device ID and generates a fresh one. Called on `Monitoor.reset()`.
    @discardableResult
    func regenerate() -> String {
        let new = UUID().uuidString
        Self.write(new)
        return new
    }

    // MARK: - Keychain

    private static func read() -> String? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      account,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    private static func write(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let attributes: [CFString: Any] = [
            kSecClass:                      kSecClassGenericPassword,
            kSecAttrService:                service,
            kSecAttrAccount:                account,
            kSecValueData:                  data,
            kSecAttrAccessible:             kSecAttrAccessibleAfterFirstUnlock,
        ]
        // Delete before writing to handle reinstall scenario.
        SecItemDelete(attributes as CFDictionary)
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
