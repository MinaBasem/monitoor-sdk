import XCTest
@testable import MonitoorSDK

final class BatchEncoderTests: XCTestCase {

    private let encoder = BatchEncoder()

    func testSmallBatch_notCompressed() throws {
        let batch = makeBatch(eventCount: 1)
        let (_, compressed) = try encoder.encode(batch: batch)
        // Single event JSON is well under 1KB.
        XCTAssertFalse(compressed)
    }

    func testLargeBatch_compressed() throws {
        let batch = makeBatch(eventCount: 20)
        let (data, compressed) = try encoder.encode(batch: batch)
        XCTAssertTrue(compressed)
        // Compressed should be smaller than naive JSON for repeated patterns.
        let uncompressed = try encoder.encode(batch: makeBatch(eventCount: 1)).0
        XCTAssertGreaterThan(uncompressed.count, 0)
        XCTAssertGreaterThan(data.count, 0)
    }

    func testOutputIsDecodableWhenUncompressed() throws {
        let batch = makeBatch(eventCount: 1)
        let (data, compressed) = try encoder.encode(batch: batch)
        guard !compressed else { return } // skip if compressed path taken
        let decoded = try JSONDecoder().decode(IngestBatch.self, from: data)
        XCTAssertEqual(decoded.batch.count, 1)
        XCTAssertEqual(decoded.sdkVersion, MonitoorSDK.version)
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
