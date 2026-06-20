import XCTest
@testable import MonitoorSDK

final class ConsentTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "monitoor.consent.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultIsOptedIn() {
        let consent = ConsentManager(store: defaults)
        XCTAssertFalse(consent.isOptedOut)
    }

    func testOptOut() {
        let consent = ConsentManager(store: defaults)
        consent.optOut()
        XCTAssertTrue(consent.isOptedOut)
    }

    func testOptInAfterOptOut() {
        let consent = ConsentManager(store: defaults)
        consent.optOut()
        consent.optIn()
        XCTAssertFalse(consent.isOptedOut)
    }

    func testOptOutPersistsAcrossInstances() {
        let consent1 = ConsentManager(store: defaults)
        consent1.optOut()

        // A fresh instance reading the same store should remain opted out.
        let consent2 = ConsentManager(store: defaults)
        XCTAssertTrue(consent2.isOptedOut)
    }
}
