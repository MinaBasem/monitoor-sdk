import XCTest
@testable import MonitoorSDK

final class SuperPropertiesTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "monitoor.superprops.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testRegisterAndAll() {
        let sp = SuperProperties(store: defaults)
        sp.register(["app_tier": "pro", "count": 3])
        let all = sp.all()
        XCTAssertEqual(all["app_tier"] as? String, "pro")
        XCTAssertEqual(all["count"] as? Int, 3)
    }

    func testRegisterMergesAndOverwrites() {
        let sp = SuperProperties(store: defaults)
        sp.register(["a": "1", "b": "2"])
        sp.register(["b": "overwritten", "c": "3"])
        let all = sp.all()
        XCTAssertEqual(all["a"] as? String, "1")
        XCTAssertEqual(all["b"] as? String, "overwritten")
        XCTAssertEqual(all["c"] as? String, "3")
    }

    func testUnregister() {
        let sp = SuperProperties(store: defaults)
        sp.register(["keep": "yes", "drop": "no"])
        sp.unregister("drop")
        let all = sp.all()
        XCTAssertEqual(all["keep"] as? String, "yes")
        XCTAssertNil(all["drop"])
    }

    func testClear() {
        let sp = SuperProperties(store: defaults)
        sp.register(["a": "1", "b": "2"])
        sp.clear()
        XCTAssertTrue(sp.all().isEmpty)
    }

    func testPersistenceAcrossInstances() {
        let sp1 = SuperProperties(store: defaults)
        sp1.register(["persisted": "value"])

        // A fresh instance reading the same store should see the value.
        let sp2 = SuperProperties(store: defaults)
        XCTAssertEqual(sp2.all()["persisted"] as? String, "value")
    }
}
