# MonitoorSDK for iOS

Track events, screen views, revenue, and crashes from your iOS app. Data streams to your Monitoor dashboard in real time.

- **Minimum iOS:** 15.0
- **Language:** Swift 5.9+
- **Dependencies:** None (Foundation, StoreKit, SQLite3 — all system-provided)
- **Binary footprint:** < 500 KB

---

## Installation

### Swift Package Manager (recommended)

In Xcode: **File → Add Package Dependencies…** and enter:

```
https://github.com/monitoor/ios-sdk-swift
```

Or add to your `Package.swift`:

```swift
.package(url: "https://github.com/monitoor/ios-sdk-swift", from: "1.0.0")
```

### CocoaPods

```ruby
pod 'MonitoorSDK'
```

---

## Quick Start

### 1. Get your API key

Sign in at [monitoor.io](https://monitoor.io), open your app's settings, and copy the API key:
- **Production:** starts with `mn_live_`
- **Development:** starts with `mn_dev_`

### 2. Initialize the SDK

Call `Monitoor.configure()` as early as possible — ideally in your app entry point before any view appears.

**SwiftUI**

```swift
import MonitoorSDK

@main
struct MyApp: App {
    init() {
        Monitoor.configure(
            apiKey: "mn_live_YOUR_KEY_HERE",
            options: MonitoorOptions(
                ingestURL: URL(string: "https://ingest.monitoor.io")!,
                environment: .production
            )
        )
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

**UIKit**

```swift
import MonitoorSDK

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        Monitoor.configure(
            apiKey: "mn_live_YOUR_KEY_HERE",
            options: MonitoorOptions(environment: .production)
        )
        return true
    }
}
```

That's it. The SDK immediately begins capturing `$app_open` events, screen views (UIKit), crashes, and StoreKit 2 revenue.

---

## Configuration Reference

All options have sensible defaults. Only override what you need.

```swift
MonitoorOptions(
    ingestURL: URL(string: "https://ingest.monitoor.io")!,

    // .production or .development. Must match your API key prefix.
    environment: .production,

    // Capture subsystems — all true by default except heatmaps and recordings.
    captureEvents: true,
    captureScreenViews: true,   // UIKit: automatic. SwiftUI: use .monitoorScreen() modifier.
    captureRevenue: true,       // StoreKit 2 transactions are captured automatically.
    captureCrashes: true,

    captureClickHeatmaps: false,     // opt-in — privacy-sensitive
    captureSessionRecordings: false, // opt-in — privacy-sensitive

    // Performance tuning.
    flushInterval: 20,         // seconds between scheduled flushes
    flushBatchSize: 50,        // events per HTTP request
    maxBufferAge: 72 * 3600,   // drop unsent events older than 72 hours
    sessionTimeout: 30 * 60    // new session after 30 min of inactivity
)
```

### Local development

Point the SDK at your local ingest service during development:

```swift
Monitoor.configure(
    apiKey: "mn_dev_YOUR_DEV_KEY",
    options: MonitoorOptions(
        ingestURL: URL(string: "http://localhost:8080")!,
        environment: .development
    )
)
```

---

## Tracking Events

### Simple event

```swift
Monitoor.track("button_tapped")
```

### Event with properties

Property values can be `String`, `Int`, `Double`, or `Bool`.

```swift
Monitoor.track("portfolio_created", properties: [
    "asset_count": 5,
    "template": "growth",
    "is_first": true
])
```

### Timed events

Call `startTimer()` when an operation begins. The elapsed time is automatically attached as `$duration` (in seconds) when you call `track()` with the same name.

```swift
Monitoor.startTimer("onboarding_flow")

// ... user completes onboarding ...

Monitoor.track("onboarding_flow")
// → event contains "$duration": 47.3
```

---

## Screen Views

### UIKit (automatic)

Screen views are captured automatically for every `UIViewController.viewDidAppear()`. The screen name is derived from the class name with common suffixes removed (`ViewController`, `Controller`, `VC`).

`PortfolioViewController` → `"Portfolio"`

No code required.

### SwiftUI (modifier)

```swift
struct PortfolioView: View {
    var body: some View {
        List { ... }
            .monitoorScreen("Portfolio")
    }
}
```

With properties:

```swift
.monitoorScreen("Stock Detail", properties: ["symbol": "AAPL"])
```

### Manual

Call this directly if you need full control over the name:

```swift
Monitoor.screen("Custom Screen Name")
```

---

## User Identity

### Identify a user

The SDK is anonymous by default. Call `identify()` after the user signs in. The user ID is SHA-256 hashed on-device before transmission — Monitoor never receives the plaintext ID.

```swift
Monitoor.identify(userId: currentUser.id)
```

### Attach user properties

Attach non-PII attributes that persist across events for this user.

```swift
Monitoor.setUserProperties([
    "plan": "pro",
    "account_age_days": 120,
    "has_verified_email": true
])
```

### Sign out

Clears the user identity and generates a new anonymous device ID so future events cannot be correlated with the previous user.

```swift
Monitoor.reset()
```

---

## Revenue Tracking

### StoreKit 2 (automatic)

When `captureRevenue: true` (the default), all verified StoreKit 2 transactions are captured automatically. No extra code required.

### StoreKit 1 or manual

```swift
Monitoor.trackRevenue(
    productId: "com.example.premium_annual",
    amount: 49.99,
    currency: "USD",
    type: .subscription,
    transactionId: payment.transaction.transactionIdentifier ?? ""
)
```

**`RevenueType` values:** `.subscription`, `.oneTime`, `.consumable`

---

## Crash Reporting

Crash reporting is enabled by default (`captureCrashes: true`). The SDK installs:

- `NSSetUncaughtExceptionHandler` — catches Swift/ObjC exceptions
- `sigaction` handlers — catches `SIGABRT`, `SIGSEGV`, `SIGBUS`, `SIGILL`, `SIGFPE`, `SIGTRAP`

Crash reports are written to disk in the signal handler using only async-signal-safe operations (no malloc, no ObjC). On the **next app launch**, the SDK uploads the report before any events are sent.

### Symbol resolution

Crash frames are uploaded as raw addresses. To see function names and line numbers in the dashboard, upload your dSYM file after each build:

```bash
curl -X POST https://ingest.monitoor.io/v1/apps/YOUR_APP_ID/dsym \
  -H "Authorization: Bearer mn_live_..." \
  -F "file=@/path/to/YourApp.app.dSYM.zip" \
  -F "build_uuid=YOUR_BUILD_UUID" \
  -F "app_version=2.1.0" \
  -F "build=214"
```

Automate this in your CI pipeline.

---

## How the SDK Works Internally

Understanding this helps debug issues and evaluate privacy impact.

### Local buffer

Every event is written synchronously to a SQLite database (`Library/monitoor_buffer.db`) before `track()` returns. This guarantees no events are lost regardless of network state, app kills, or crashes.

### Flush engine

Events are batched and streamed to the ingest service over HTTPS. The engine drains the buffer in batches of up to `flushBatchSize` events. Flushing is triggered by:

| Trigger | When |
|---|---|
| Batch full | `flushBatchSize` events accumulated |
| App background | `UIScene.willDeactivateNotification` |
| App terminate | `UIApplication.willTerminateNotification` |
| Timer | Every `flushInterval` seconds |
| Network restored | `NWPathMonitor` path becomes `.satisfied` |

### Retry behaviour

| HTTP response | Action |
|---|---|
| `2xx` | Events deleted from buffer |
| `4xx` (client error) | Events marked as permanently failed (not retried) |
| `429` Too Many Requests | Back off for `Retry-After` seconds, retry later |
| `5xx` / network error | Exponential back-off (1s, 2s, 4s … max 5 min), retry |

### Idempotency

Every event carries an `idempotency_key` (`device_id + session_id + timestamp`). The ingest service uses `ON CONFLICT DO NOTHING`, so retried batches never produce duplicate rows.

---

## Privacy

| Data | Collected | Notes |
|---|---|---|
| Device ID | Yes | UUID in Keychain — not linked to Apple ID, IDFA, or any real identity |
| IP address | No | Resolved to country server-side, then immediately discarded |
| User ID | Optional | SHA-256 hashed on-device before transmission |
| Screen recordings | No (default) | Opt-in via `captureSessionRecordings: true` |
| Keystrokes / clipboard | Never | — |
| Precise location | Never | — |
| IDFA / IDFV | Never | No ATT prompt required |
| Push token | Never | — |

The SDK requires **no `NSPrivacyAccessedAPITypes`** entries in `PrivacyInfo.xcprivacy` and triggers no App Tracking Transparency prompt.

---

## FAQ

**Does the SDK connect to my database directly?**
No. It only sends HTTPS requests to the ingest service. Database credentials never leave your server.

**What happens when the user is offline?**
Events are buffered in SQLite indefinitely (up to `maxBufferAge`, default 72 hours). Once connectivity is restored, the buffer drains automatically.

**Can I use the SDK in a SwiftUI preview?**
Yes, but call `Monitoor.configure()` conditionally:
```swift
if !ProcessInfo.processInfo.environment.keys.contains("XCODE_RUNNING_FOR_PREVIEWS") {
    Monitoor.configure(apiKey: "mn_dev_...")
}
```

**Can I call `Monitoor.configure()` more than once?**
No. Only the first call takes effect. Subsequent calls are silently ignored.

**How do I verify events are reaching the ingest service during development?**
Check the Monitoor development dashboard, or query your local PostgreSQL directly:
```sql
SELECT name, occurred_at, properties FROM events ORDER BY occurred_at DESC LIMIT 20;
```

---

## Troubleshooting

| Symptom | Check |
|---|---|
| No events in dashboard | Verify `apiKey` prefix matches `environment`. Check `[Monitoor]` console logs in DEBUG builds. |
| Events appear but are delayed | Default flush interval is 20s. Call `Monitoor.flush()` for immediate delivery. |
| Crash reports not appearing | Verify `captureCrashes: true`. Crashes upload on the **next** launch, not the crashing one. |
| `mn_live_` key rejected | Ensure `environment: .production` in `MonitoorOptions`. |
| High data usage | Reduce `flushBatchSize` or increase `flushInterval`. Events are gzip-compressed above 1 KB. |
