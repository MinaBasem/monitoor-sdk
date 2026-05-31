import Foundation

public struct MonitoorOptions: Sendable {

    public enum Environment: String, Sendable {
        case production  = "production"
        case development = "development"
    }

    /// The URL of the Monitoor ingest service.
    public var ingestURL: URL

    /// Whether this instance targets production or development.
    /// Must match your API key prefix: `mn_live_` → `.production`, `mn_dev_` → `.development`.
    public var environment: Environment

    /// Capture custom `track()` events. Matches the `captureEvents` column on the ApiKey record.
    public var captureEvents: Bool

    /// Capture screen view events (UIKit: automatic via swizzle; SwiftUI: `.monitoorScreen()` modifier).
    /// Matches the `captureScreens` column on the ApiKey record.
    public var captureScreens: Bool

    /// Capture StoreKit 2 revenue transactions automatically.
    /// Matches the `captureRevenue` column on the ApiKey record.
    public var captureRevenue: Bool

    /// Install signal/exception crash handlers.
    /// Matches the `captureCrashes` column on the ApiKey record.
    public var captureCrashes: Bool

    /// Opt-in: capture click heatmap data (privacy-sensitive, off by default).
    /// Matches the `captureHeatmaps` column on the ApiKey record.
    public var captureHeatmaps: Bool

    /// Opt-in: capture session recordings (privacy-sensitive, off by default).
    /// Matches the `captureRecordings` column on the ApiKey record.
    public var captureRecordings: Bool

    /// Event sampling multiplier (0.0 – 1.0). Mirrors the `mul` column on the ApiKey record.
    /// 1.0 = send every event; 0.5 = send ~50% of events at random.
    /// The ingest service uses the same value for statistical weighting.
    public var sampleRate: Double

    /// Drop unsent events older than this many days. Mirrors the `retention` column (default 90 days).
    public var retentionDays: Int

    /// Seconds between scheduled flush timer fires. Default: 20.
    public var flushInterval: TimeInterval

    /// Maximum events per HTTP request. Default: 50.
    public var flushBatchSize: Int

    /// Session inactivity timeout. Default: 30 minutes.
    public var sessionTimeout: TimeInterval

    /// Derived max buffer age from `retentionDays`.
    var maxBufferAge: TimeInterval { TimeInterval(retentionDays) * 86_400 }

    public init(
        ingestURL: URL = URL(string: "https://ingest.monitoor.io")!,
        environment: Environment = .production,
        captureEvents: Bool = true,
        captureScreens: Bool = true,
        captureRevenue: Bool = true,
        captureCrashes: Bool = true,
        captureHeatmaps: Bool = false,
        captureRecordings: Bool = false,
        sampleRate: Double = 1.0,
        retentionDays: Int = 90,
        flushInterval: TimeInterval = 20,
        flushBatchSize: Int = 50,
        sessionTimeout: TimeInterval = 30 * 60
    ) {
        self.ingestURL       = ingestURL
        self.environment     = environment
        self.captureEvents   = captureEvents
        self.captureScreens  = captureScreens
        self.captureRevenue  = captureRevenue
        self.captureCrashes  = captureCrashes
        self.captureHeatmaps = captureHeatmaps
        self.captureRecordings = captureRecordings
        self.sampleRate      = max(0.0, min(1.0, sampleRate))
        self.retentionDays   = max(1, retentionDays)
        self.flushInterval   = flushInterval
        self.flushBatchSize  = flushBatchSize
        self.sessionTimeout  = sessionTimeout
    }
}
