import XCTest
@testable import MonitoorSDK

final class RuntimeConfigTests: XCTestCase {

    func testSeededFromOptions() {
        let options = MonitoorOptions(
            captureEvents: true,
            captureScreens: false,
            captureRevenue: true,
            sampleRate: 0.5,
            retentionDays: 30
        )
        let config = RuntimeConfig(options: options)
        XCTAssertTrue(config.captureEvents)
        XCTAssertFalse(config.captureScreens)
        XCTAssertTrue(config.captureRevenue)
        XCTAssertEqual(config.sampleRate, 0.5)
        XCTAssertEqual(config.retentionDays, 30)
    }

    func testApplyRemoteOverrides() {
        let config = RuntimeConfig(options: MonitoorOptions())
        let remote = RemoteConfigResponse(
            captureEvents: false,
            captureScreens: false,
            captureRevenue: false,
            captureCrashes: false,
            captureHeatmaps: true,
            captureRecordings: true,
            mul: 0.25,
            retention: 7
        )
        config.apply(remote)
        XCTAssertFalse(config.captureEvents)
        XCTAssertFalse(config.captureScreens)
        XCTAssertFalse(config.captureRevenue)
        XCTAssertEqual(config.sampleRate, 0.25)
        XCTAssertEqual(config.retentionDays, 7)
    }

    func testApplyClampsSampleRateAndRetention() {
        let config = RuntimeConfig(options: MonitoorOptions())
        let remote = RemoteConfigResponse(
            captureEvents: true, captureScreens: true, captureRevenue: true,
            captureCrashes: true, captureHeatmaps: false, captureRecordings: false,
            mul: 5.0,          // out of range, should clamp to 1.0
            retention: 0       // invalid, should clamp to >= 1
        )
        config.apply(remote)
        XCTAssertEqual(config.sampleRate, 1.0)
        XCTAssertGreaterThanOrEqual(config.retentionDays, 1)
    }

    func testConcurrentReadsWritesDoNotCrash() {
        let config = RuntimeConfig(options: MonitoorOptions())
        let group = DispatchGroup()
        for i in 0..<200 {
            group.enter()
            DispatchQueue.global().async {
                if i % 2 == 0 {
                    _ = config.sampleRate
                    _ = config.captureEvents
                } else {
                    config.apply(RemoteConfigResponse(
                        captureEvents: true, captureScreens: true, captureRevenue: true,
                        captureCrashes: true, captureHeatmaps: false, captureRecordings: false,
                        mul: 0.5, retention: 30
                    ))
                }
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(config.sampleRate, 0.5)
    }
}
