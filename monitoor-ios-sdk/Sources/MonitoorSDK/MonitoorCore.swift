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
        deviceIdentity = DeviceIdentity()
        userIdentity   = UserIdentity()
        sessionManager = SessionManager(timeout: options.sessionTimeout)
        deviceInfo     = DeviceInfo.current()
        localBuffer    = try LocalBuffer()
        httpClient     = HTTPClient()

        flushEngine = FlushEngine(
            buffer: localBuffer,
            httpClient: httpClient,
            apiKey: apiKey,
            options: options
        )

        eventCapture = EventCapture(
            buffer: localBuffer,
            sessionManager: sessionManager,
            identity: userIdentity,
            deviceIdentity: deviceIdentity,
            deviceInfo: deviceInfo,
            flushEngine: flushEngine,
            options: options
        )

        let crashDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("monitoor_crashes")

        crashCapture = CrashCapture(
            crashDirectory: crashDir,
            httpClient: httpClient,
            apiKey: apiKey,
            ingestURL: options.ingestURL
        )

        revenueCapture = RevenueCapture(eventCapture: eventCapture)

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

        // Synthetic app_open event.
        eventCapture.track("$app_open", properties: [:])
    }

    // MARK: - Public API implementations

    func capture(name: String, properties: [String: Any]) {
        guard isConfigured else { return }
        eventCapture.track(name, properties: properties)
    }

    func captureScreen(_ name: String, properties: [String: Any]) {
        guard isConfigured, options.captureScreens else { return }
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
            // Attach session duration so the dashboard knows how long this foreground session lasted.
            let duration = self.sessionManager.duration
            self.eventCapture.track("$app_background", properties: [
                "$session_duration_s": duration
            ])
        }
    }
}
