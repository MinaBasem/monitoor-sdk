import Foundation

/// The Monitoor SDK public API. All methods are safe to call from any thread.
///
/// Initialize once in your app entry point:
/// ```swift
/// Monitoor.configure(apiKey: "mn_live_...", options: MonitoorOptions())
/// ```
public final class Monitoor {

    // MARK: - Configuration

    /// Initializes the SDK. Must be called before any other method, typically in `App.init()`.
    ///
    /// - Parameters:
    ///   - apiKey: Your Monitoor API key (`mn_live_…` for production, `mn_dev_…` for development).
    ///   - options: Optional configuration overrides.
    public static func configure(apiKey: String, options: MonitoorOptions = MonitoorOptions()) {
        core.setup(apiKey: apiKey, options: options)
    }

    // MARK: - Event tracking

    /// Tracks a named event with optional properties.
    ///
    /// ```swift
    /// Monitoor.track("button_tapped")
    /// Monitoor.track("purchase_completed", properties: ["plan": "pro", "amount": 9.99])
    /// ```
    public static func track(_ name: String, properties: [String: Any] = [:]) {
        core.capture(name: name, properties: properties)
    }

    /// Tracks a screen view. Use the SwiftUI `.monitoorScreen()` modifier instead for SwiftUI views.
    public static func screen(_ name: String, properties: [String: Any] = [:]) {
        core.captureScreen(name, properties: properties)
    }

    // MARK: - Timed events

    /// Starts an event timer. The elapsed duration is automatically attached when you call `track()` with the same name.
    ///
    /// ```swift
    /// Monitoor.startTimer("checkout_flow")
    /// // ...user completes checkout...
    /// Monitoor.track("checkout_flow")  // $duration property is added automatically
    /// ```
    public static func startTimer(_ name: String) {
        core.startTimer(name)
    }

    // MARK: - User identity

    /// Associates subsequent events with a user. The ID is SHA-256 hashed before transmission.
    ///
    /// ```swift
    /// Monitoor.identify(userId: currentUser.id)
    /// ```
    public static func identify(userId: String) {
        core.identify(userId: userId)
    }

    /// Attaches non-PII properties to the current user (e.g. plan, account age).
    ///
    /// ```swift
    /// Monitoor.setUserProperties(["plan": "pro", "account_age_days": 120])
    /// ```
    public static func setUserProperties(_ properties: [String: Any]) {
        core.setUserProperties(properties)
    }

    /// Clears the current user identity and generates a new anonymous device ID. Call on sign-out.
    public static func reset() {
        core.reset()
    }

    // MARK: - Revenue

    /// Manually tracks a revenue event. Use this for StoreKit 1 or non-StoreKit purchases.
    /// StoreKit 2 transactions are captured automatically when `captureRevenue: true`.
    ///
    /// ```swift
    /// Monitoor.trackRevenue(
    ///     productId: "com.example.premium",
    ///     amount: 9.99,
    ///     currency: "USD",
    ///     type: .subscription,
    ///     transactionId: payment.transaction.transactionIdentifier ?? ""
    /// )
    /// ```
    public static func trackRevenue(
        productId: String,
        amount: Double,
        currency: String,
        type: RevenueType,
        transactionId: String
    ) {
        core.trackRevenue(
            productId: productId,
            amount: amount,
            currency: currency,
            type: type,
            transactionId: transactionId
        )
    }

    // MARK: - Session

    /// Elapsed time in seconds since the current session started.
    ///
    /// A new session begins when the app opens, or after 30 minutes of inactivity in the background.
    ///
    /// ```swift
    /// let seconds = Monitoor.sessionDuration  // e.g. 142.7
    /// ```
    public static var sessionDuration: TimeInterval {
        core.sessionDuration
    }

    // MARK: - Super properties

    /// Registers global properties that are automatically merged into every event.
    /// Event-specific properties override super properties on key conflict.
    /// Persisted across launches.
    ///
    /// ```swift
    /// Monitoor.registerSuperProperties(["app_tier": "pro", "ab_cohort": "B"])
    /// ```
    public static func registerSuperProperties(_ properties: [String: Any]) {
        core.registerSuperProperties(properties)
    }

    /// Removes a single super property by key.
    public static func unregisterSuperProperty(_ key: String) {
        core.unregisterSuperProperty(key)
    }

    /// Removes all super properties.
    public static func clearSuperProperties() {
        core.clearSuperProperties()
    }

    // MARK: - Consent

    /// Whether the user has opted out of analytics collection.
    public static var isOptedOut: Bool {
        core.isOptedOut
    }

    /// Opts the user out of all analytics. Stops capture and flushing, and purges
    /// any locally buffered events. The choice persists across launches.
    public static func optOut() {
        core.optOut()
    }

    /// Re-enables analytics collection after a previous `optOut()`.
    public static func optIn() {
        core.optIn()
    }

    // MARK: - Manual flush

    /// Forces an immediate flush of all buffered events. Useful in testing or before critical operations.
    public static func flush(completion: (() -> Void)? = nil) {
        core.flush(completion: completion)
    }

    // MARK: - Internal

    static let core = MonitoorCore()
    private init() {}
}

// MARK: - SDK metadata

enum MonitoorSDK {
    static let version = "1.0.0"

    static func log(_ message: String) {
        #if DEBUG
        print("[Monitoor] \(message)")
        #endif
    }
}
