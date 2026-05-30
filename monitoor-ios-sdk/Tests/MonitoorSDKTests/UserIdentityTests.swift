import XCTest
import CryptoKit
@testable import MonitoorSDK

final class UserIdentityTests: XCTestCase {

    func testSetUserId_storesHash() {
        let identity = UserIdentity()
        identity.setUserId("user-123")

        let expected = SHA256.hash(data: Data("user-123".utf8))
            .compactMap { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(identity.userIdHash, expected)
    }

    func testSetUserId_differentInputs_differentHashes() {
        let identity = UserIdentity()
        identity.setUserId("alice")
        let hash1 = identity.userIdHash

        identity.setUserId("bob")
        let hash2 = identity.userIdHash

        XCTAssertNotEqual(hash1, hash2)
    }

    func testReset_clearsUserIdAndProperties() {
        let identity = UserIdentity()
        identity.setUserId("user-123")
        identity.setProperties(["plan": "pro"])

        identity.reset()

        XCTAssertNil(identity.userIdHash)
        XCTAssertTrue(identity.properties.isEmpty)
    }

    func testSetProperties_mergesKeys() {
        let identity = UserIdentity()
        identity.setProperties(["a": "1"])
        identity.setProperties(["b": "2"])

        XCTAssertEqual(identity.properties["a"] as? String, "1")
        XCTAssertEqual(identity.properties["b"] as? String, "2")
    }

    func testSetProperties_newValueOverridesOld() {
        let identity = UserIdentity()
        identity.setProperties(["plan": "free"])
        identity.setProperties(["plan": "pro"])

        XCTAssertEqual(identity.properties["plan"] as? String, "pro")
    }
}
