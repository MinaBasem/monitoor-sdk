import XCTest
@testable import MonitoorSDK

final class SessionTests: XCTestCase {

    func testInitialSessionIdIsStable() {
        let manager = SessionManager(timeout: 30 * 60)
        let id1 = manager.currentSessionId
        let id2 = manager.currentSessionId
        XCTAssertEqual(id1, id2)
    }

    func testNewSessionAfterTimeout() {
        let manager = SessionManager(timeout: 0.001) // 1ms timeout
        let id1 = manager.currentSessionId
        Thread.sleep(forTimeInterval: 0.01)
        manager.handleForeground()
        let id2 = manager.currentSessionId
        XCTAssertNotEqual(id1, id2)
    }

    func testSameSessionWithinTimeout() {
        let manager = SessionManager(timeout: 30 * 60)
        let id1 = manager.currentSessionId
        manager.recordActivity()
        let changed = manager.handleForeground()
        let id2 = manager.currentSessionId
        XCTAssertFalse(changed)
        XCTAssertEqual(id1, id2)
    }

    func testResetGeneratesNewSession() {
        let manager = SessionManager(timeout: 30 * 60)
        let id1 = manager.currentSessionId
        manager.reset()
        let id2 = manager.currentSessionId
        XCTAssertNotEqual(id1, id2)
    }

    func testHandleForeground_returnsTrue_whenTimedOut() {
        let manager = SessionManager(timeout: 0.001)
        Thread.sleep(forTimeInterval: 0.01)
        let newSession = manager.handleForeground()
        XCTAssertTrue(newSession)
    }

    func testHandleForeground_returnsFalse_whenActive() {
        let manager = SessionManager(timeout: 30 * 60)
        manager.recordActivity()
        let newSession = manager.handleForeground()
        XCTAssertFalse(newSession)
    }
}
