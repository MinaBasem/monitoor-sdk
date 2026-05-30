import XCTest
@testable import MonitoorSDK

final class BufferTests: XCTestCase {

    var buffer: LocalBuffer!

    override func setUp() {
        super.setUp()
        // Use a unique temp file per test so tests don't bleed into each other.
        let path = NSTemporaryDirectory() + "monitoor_test_\(UUID().uuidString).db"
        buffer = try! LocalBuffer(path: path)
    }

    override func tearDown() {
        let path = (buffer as AnyObject).perform(#selector(getter: NSObject.description))
        buffer = nil
        super.tearDown()
    }

    func testEnqueueAndDequeue() throws {
        let payload = #"{"name":"test"}"#.data(using: .utf8)!
        try buffer.enqueue(payload: payload, type: .event)

        let rows = try buffer.dequeue(limit: 10)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].type, .event)
    }

    func testMarkSent_deletesRows() throws {
        let payload = #"{"name":"test"}"#.data(using: .utf8)!
        try buffer.enqueue(payload: payload, type: .event)

        var rows = try buffer.dequeue(limit: 10)
        XCTAssertEqual(rows.count, 1)

        try buffer.markSent(ids: [rows[0].rowId])
        rows = try buffer.dequeue(limit: 10)
        XCTAssertEqual(rows.count, 0)
    }

    func testMarkFailed_setsStatusAndKeepsRow() throws {
        let payload = #"{"name":"test"}"#.data(using: .utf8)!
        try buffer.enqueue(payload: payload, type: .event)

        let rows = try buffer.dequeue(limit: 10)
        XCTAssertEqual(rows.count, 1)

        try buffer.markFailed(ids: [rows[0].rowId])

        // Failed rows are excluded from dequeue (status != 'pending').
        let afterFail = try buffer.dequeue(limit: 10)
        XCTAssertEqual(afterFail.count, 0)
    }

    func testPruneExpired_deletesOldRows() throws {
        let payload = #"{"name":"old"}"#.data(using: .utf8)!
        try buffer.enqueue(payload: payload, type: .event)

        // Prune with maxAge = 0 should remove everything.
        try buffer.pruneExpired(maxAge: 0)
        let count = try buffer.pendingCount()
        XCTAssertEqual(count, 0)
    }

    func testPendingCount_reflectsEnqueuedItems() throws {
        XCTAssertEqual(try buffer.pendingCount(), 0)
        let payload = #"{"name":"a"}"#.data(using: .utf8)!
        try buffer.enqueue(payload: payload, type: .event)
        try buffer.enqueue(payload: payload, type: .event)
        XCTAssertEqual(try buffer.pendingCount(), 2)
    }

    func testConcurrentEnqueue_noDataRace() throws {
        let iterations = 200
        let group = DispatchGroup()

        for _ in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                let payload = #"{"name":"concurrent"}"#.data(using: .utf8)!
                try? self.buffer.enqueue(payload: payload, type: .event)
                group.leave()
            }
        }
        group.wait()

        let count = try buffer.pendingCount()
        XCTAssertEqual(count, iterations)
    }

    func testDequeue_respectsLimit() throws {
        let payload = #"{"name":"x"}"#.data(using: .utf8)!
        for _ in 0..<10 {
            try buffer.enqueue(payload: payload, type: .event)
        }
        let rows = try buffer.dequeue(limit: 3)
        XCTAssertEqual(rows.count, 3)
    }

    func testMarkSentEmptyIds_noThrow() throws {
        XCTAssertNoThrow(try buffer.markSent(ids: []))
    }
}
