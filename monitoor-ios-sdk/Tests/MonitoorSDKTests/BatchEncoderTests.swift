import XCTest
@testable import MonitoorSDK

final class BatchEncoderTests: XCTestCase {

    private let encoder = BatchEncoder()

    func testBatchEncodesAndDecodes() throws {
        let batch = makeBatch(eventCount: 1)
        let data = try encoder.encode(batch: batch)
        let decoded = try JSONDecoder().decode(IngestBatch.self, from: data)
        XCTAssertEqual(decoded.batch.count, 1)
        XCTAssertEqual(decoded.sdkVersion, MonitoorSDK.version)
    }

    func testLargeBatchEncodesCorrectly() throws {
        let batch = makeBatch(eventCount: 20)
        let data = try encoder.encode(batch: batch)
        let decoded = try JSONDecoder().decode(IngestBatch.self, from: data)
        XCTAssertEqual(decoded.batch.count, 20)
    }

    func testOutputIsValidJSON() throws {
        let batch = makeBatch(eventCount: 5)
        let data = try encoder.encode(batch: batch)
        XCTAssertGreaterThan(data.count, 0)
        XCTAssertNoThrow(try JSONDecoder().decode(IngestBatch.self, from: data))
    }

    // MARK: - Helpers

    private func makeBatch(eventCount: Int) -> IngestBatch {
        let context = EventContext(
            appVersion: "1.0", build: "1", os: "iOS 17",
            device: "iPhone", locale: "en_US", timezone: "UTC", bundleId: "com.test"
        )
        let events = (0..<eventCount).map { i in
            WireEvent(
                type: "event",
                name: "test_event_\(i)",
                sessionId: UUID().uuidString,
                deviceId: UUID().uuidString,
                userIdHash: nil,
                idempotencyKey: UUID().uuidString,
                occurredAt: "2026-01-01T00:00:00.000Z",
                properties: nil,
                context: context
            )
        }
        return IngestBatch(sdkVersion: MonitoorSDK.version, batch: events)
    }
}
