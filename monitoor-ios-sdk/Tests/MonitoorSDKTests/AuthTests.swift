import XCTest
@testable import MonitoorSDK

final class AuthTests: XCTestCase {

    // Replicate the key prefix validation logic from MonitoorCore.
    private func validateKey(_ key: String, environment: MonitoorOptions.Environment) -> Bool {
        switch environment {
        case .production:  return key.hasPrefix("mn_live_")
        case .development: return key.hasPrefix("mn_dev_")
        }
    }

    func testProductionKey_passesProductionEnvironment() {
        XCTAssertTrue(validateKey("mn_live_abc123", environment: .production))
    }

    func testDevelopmentKey_passesDevelopmentEnvironment() {
        XCTAssertTrue(validateKey("mn_dev_abc123", environment: .development))
    }

    func testProductionKey_failsDevelopmentEnvironment() {
        XCTAssertFalse(validateKey("mn_live_abc123", environment: .development))
    }

    func testDevelopmentKey_failsProductionEnvironment() {
        XCTAssertFalse(validateKey("mn_dev_abc123", environment: .production))
    }

    func testEmptyKey_fails() {
        XCTAssertFalse(validateKey("", environment: .production))
        XCTAssertFalse(validateKey("", environment: .development))
    }

    func testMalformedKey_fails() {
        XCTAssertFalse(validateKey("live_abc123", environment: .production))
        XCTAssertFalse(validateKey("mn_abc123", environment: .production))
    }
}
