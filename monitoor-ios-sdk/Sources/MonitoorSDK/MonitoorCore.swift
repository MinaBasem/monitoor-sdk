import Foundation
import UIKit

/// Internal singleton that owns all SDK subsystems. Not part of the public API.
final class MonitoorCore {

    // Accessed by ScreenCapture.swift to track screen views.
    static weak var shared: MonitoorCore?

    private(set) var apiKey: String = ""
    private(set) var options: MonitoorOptions = MonitoorOptions()

    private var deviceIdentity: DeviceIdentity!
    private var userIdentity: UserIdentity!
    private var sessionManager: SessionManager!
    private var deviceInfo: DeviceInfo!
    private var localBuffer: LocalBuffer!
    private var httpClient: HTTPClient!
    private var flushEngine: FlushEngine!
    private var eventCapture: EventCapture!
    private var revenueCapture: RevenueCapture!
    private var crashCapture: CrashCapture!
    private var runtimeConfig: RuntimeConfig!
    private var superProperties: SuperProperties!
    private var consentManager: ConsentManager!

    private var isConfigured = false
    private let setupLock = NSLock()

    // MARK: - Setup

    func setup(apiKey: String, options: MonitoorOptions) {
        setupLock.withLock {
            guard !isConfigured else {
                MonitoorSDK.log("Monitoor.configure() called more than once — ignored.")
                return
            }

            guard validateKey(apiKey, environment: options.environment) else {
                MonitoorSDK.log("API key prefix does not match environment. SDK will not start.")
                return
            }

            self.apiKey  = apiKey
            self.options = options

            do {
                try bootstrap()
            } catch {
                MonitoorSDK.log("SDK bootstrap failed: \(error)")
                return
            }

            isConfigured = true
            MonitoorCore.shared = self
        }
    }

    private func bootstrap() throws {
        deviceIdentity  = DeviceIdentity()
        userIdentity    = UserIdentity()
        sessionManager  = SessionManager(timeout: options.sessionTimeout)
        deviceInfo      = DeviceInfo.current()
        localBuffer     = try LocalBuffer()
        httpClient      = HTTPClient()

        // Shared runtime state, built before subsystems that read it.
        runtimeConfig   = RuntimeConfig(options: options)
        superProperties = SuperProperties()
        consentManager  = ConsentManager()

        flushEngine = FlushEngine(
            buffer: localBuffer,
            httpClient: httpClient,
            apiKey: apiKey,
            options: options,
            runtimeConfig: runtimeConfig,
            consent: consentManager
        )

        eventCapture = EventCapture(
            buffer: localBuffer,
            sessionManager: sessionManager,
            identity: userIdentity,
            deviceIdentity: deviceIdentity,
            deviceInfo: deviceInfo,
            flushEngine: flushEngine,
            options: options,
            runtimeConfig: runtimeConfig,
            superProperties: superProperties,
            consent: consentManager
        )

        let crashDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("monitoor_crashes")

        crashCapture = CrashCapture(
            crashDirectory: crashDir,
            httpClient: httpClient,
            apiKey: apiKey,
            ingestURL: options.ingestURL
        )

        revenueCapture = RevenueCapture(eventCapture: eventCapture, runtimeConfig: runtimeConfig)

        // Upload pending crashes from the previous launch before anything else.
        if options.captureCrashes {
            crashCapture.uploadPendingCrashes()
            crashCapture.install(
                deviceInfo: deviceInfo,
                deviceId: deviceIdentity.deviceId,
                sessionId: sessionManager.currentSessionId
            )
        }

        if options.captureRevenue {
            revenueCapture.startObserving()
        }

        if options.captureScreens {
            UIViewController.monitoor_installSwizzle()
        }

        registerLifecycleObservers()
        flushEngine.start()

        // Synthetic app_open event (suppressed automatically if opted out).
        eventCapture.track("$app_open", properties: [:])

        // Fetch server-side configuration and apply it at runtime. Failures are
        // ignored — the SDK keeps the local MonitoorOptions defaults.
        fetchRemoteConfig()
    }

    private func fetchRemoteConfig() {
        let key = apiKey
        let url = options.ingestURL
        Task { [weak self] in
            guard let remote = await self?.httpClient.fetchConfig(apiKey: key, ingestURL: url) else { return }
            self?.runtimeConfig.apply(remote)
            MonitoorSDK.log("Remote config applied: events=\(remote.captureEvents) screens=\(remote.captureScreens) revenue=\(remote.captureRevenue) sampleRate=\(remote.mul)")
        }
    }

    // MARK: - Public API implementations

    func capture(name: String, properties: [String: Any]) {
        guard isConfigured, runtimeConfig.captureEvents else { return }
        eventCapture.track(name, properties: properties)
    }

    func captureScreen(_ name: String, properties: [String: Any]) {
        guard isConfigured, runtimeConfig.captureScreens else { return }
        var props = properties
        props["$screen_name"] = name
        eventCapture.enqueue(name: "$screen_view", type: "event", properties: props)
    }

    func identify(userId: String) {
        guard isConfigured else { return }
        userIdentity.setUserId(userId)
    }

    func setUserProperties(_ properties: [String: Any]) {
        guard isConfigured else { return }
        userIdentity.setProperties(properties)
    }

    func startTimer(_ name: String) {
        guard isConfigured else { return }
        eventCapture.startTimer(name)
    }

    func trackRevenue(
        productId: String,
        amount: Double,
        currency: String,
        type: RevenueType,
        transactionId: String
    ) {
        guard isConfigured else { return }
        revenueCapture.trackManual(
            productId: productId,
            amount: amount,
            currency: currency,
            type: type,
            transactionId: transactionId
        )
    }

    var sessionDuration: TimeInterval {
        guard isConfigured else { return 0 }
        return sessionManager.duration
    }

    // MARK: - Super properties

    func registerSuperProperties(_ properties: [String: Any]) {
        guard isConfigured else { return }
        superProperties.register(properties)
    }

    func unregisterSuperProperty(_ key: String) {
        guard isConfigured else { return }
        superProperties.unregister(key)
    }

    func clearSuperProperties() {
        guard isConfigured else { return }
        superProperties.clear()
    }

    // MARK: - Consent

    var isOptedOut: Bool {
        guard isConfigured else { return false }
        return consentManager.isOptedOut
    }

    func optOut() {
        guard isConfigured else { return }
        consentManager.optOut()
        // Purge anything already buffered so opted-out data never leaves the device.
        try? localBuffer.clearAll()
    }

    func optIn() {
        guard isConfigured else { return }
        consentManager.optIn()
    }

    func flush(completion: (() -> Void)?) {
        guard isConfigured else { completion?(); return }
        flushEngine.flush(completion: completion)
    }

    func reset() {
        guard isConfigured else { return }
        userIdentity.reset()
        sessionManager.reset()
        // Generate a new device_id so prior data can't be correlated.
        deviceIdentity.regenerate()
        eventCapture.track("$app_open", properties: [:])
    }

    // MARK: - Key validation

    private func validateKey(_ key: String, environment: MonitoorOptions.Environment) -> Bool {
        switch environment {
        case .production:  return key.hasPrefix("mn_live_")
        case .development: return key.hasPrefix("mn_dev_")
        }
    }

    // MARK: - Lifecycle

    private func registerLifecycleObservers() {
        let nc = NotificationCenter.default

        nc.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            if self.sessionManager.handleForeground() {
                self.eventCapture.track("$app_open", properties: [:])
            }
        }

        nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            // Freeze the foreground timer first, then read the accurate duration.
            self.sessionManager.handleBackground()
            self.eventCapture.track("$app_background", properties: [
                "$session_duration_s": self.sessionManager.duration
            ])
        }
    }
}
