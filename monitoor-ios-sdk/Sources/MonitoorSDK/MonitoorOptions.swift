import Foundation

public struct MonitoorOptions: Sendable {

    public enum Environment: String, Sendable {
        case production  = "production"
        case development = "development"
    }

    /// The URL of the Monitoor ingest service.
    public var ingestURL: URL

    /// Whether this instance targets production or development.
    public var environment: Environment

    /// Automatically capture custom `track()` events. Default: true.
    public var captureEvents: Bool

    /// Automatically capture screen view events (UIKit swizzle + SwiftUI modifier). Default: true.
    public var captureScreenViews: Bool

    /// Automatically capture StoreKit 2 revenue transactions. Default: true.
    public var captureRevenue: Bool

    /// Install signal/exception crash handlers. Default: true.
    public var captureCrashes: Bool

    /// Opt-in: capture click heatmap data (privacy-sensitive). Default: false.
    public var captureClickHeatmaps: Bool

    /// Opt-in: capture session recordings (privacy-sensitive). Default: false.
    public var captureSessionRecordings: Bool

    /// Seconds between scheduled flush timer fires. Default: 20.
    public var flushInterval: TimeInterval

    /// Maximum events per HTTP request. Default: 50.
    public var flushBatchSize: Int

    /// Drop unsent events older than this interval. Default: 72 hours.
    public var maxBufferAge: TimeInterval

    /// Session inactivity timeout. Default: 30 minutes.
    public var sessionTimeout: TimeInterval

    public init(
        ingestURL: URL = URL(string: "https://ingest.monitoor.io")!,
        environment: Environment = .production,
        captureEvents: Bool = true,
        captureScreenViews: Bool = true,
        captureRevenue: Bool = true,
        captureCrashes: Bool = true,
        captureClickHeatmaps: Bool = false,
        captureSessionRecordings: Bool = false,
        flushInterval: TimeInterval = 20,
        flushBatchSize: Int = 50,
        maxBufferAge: TimeInterval = 72 * 3600,
        sessionTimeout: TimeInterval = 30 * 60
    ) {
        self.ingestURL = ingestURL
        self.environment = environment
        self.captureEvents = captureEvents
        self.captureScreenViews = captureScreenViews
        self.captureRevenue = captureRevenue
        self.captureCrashes = captureCrashes
        self.captureClickHeatmaps = captureClickHeatmaps
        self.captureSessionRecordings = captureSessionRecordings
        self.flushInterval = flushInterval
        self.flushBatchSize = flushBatchSize
        self.maxBufferAge = maxBufferAge
        self.sessionTimeout = sessionTimeout
    }
}
