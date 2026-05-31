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

Sign up at [monitoor.io](https://monitoor.io) and create a project. Once inside, navigate to your project's **API Keys** section and generate a key.

- **Production key** — prefix `mn_live_` — use in App Store / TestFlight builds
- **Development key** — prefix `mn_dev_` — use in local development and the Simulator

> **Coming soon:** API keys will also be creatable via the Monitoor CLI for teams that prefer a code-first or CI-driven workflow.

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
            options: MonitoorOptions(environment: .production)
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
    // Must match your API key prefix: mn_live_ → .production, mn_dev_ → .development
    environment: .production,

    // Capture subsystems — on by default except heatmaps and recordings.
    captureEvents: true,
    captureScreens: true,      // UIKit: automatic. SwiftUI: use .monitoorScreen() modifier.
    captureRevenue: true,      // StoreKit 2 transactions captured automatically.
    captureCrashes: true,

    captureHeatmaps: false,    // opt-in — privacy-sensitive
    captureRecordings: false,  // opt-in — privacy-sensitive

    // Event sampling (mirrors the `mul` field on your API key record).
    // 1.0 = send every event. 0.1 = send ~10% of events at random.
    // System events ($app_open, $app_background, etc.) are never sampled out.
    sampleRate: 1.0,

    // How long to retain unsent events in the local buffer (mirrors the `retention` field).
    retentionDays: 90,

    // Flush tuning.
    flushInterval: 20,         // seconds between scheduled flushes
    flushBatchSize: 50,        // events per HTTP request
    sessionTimeout: 30 * 60   // new session after this many seconds of inactivity
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

## Button Tracking

The easiest way to count button presses — no need to add `Monitoor.track()` calls inside action closures.

### SwiftUI — `.monitoorTap()` modifier

Attach to any tappable view. Fires alongside the button's own action.

```swift
// Basic
Button("Subscribe") { subscribe() }
    .monitoorTap("subscribe_tapped")

// With properties
Button("Delete Account") { confirmDelete() }
    .monitoorTap("delete_account_tapped", properties: ["source": "settings"])

// Works on any tappable view, not just Button
Image(systemName: "heart")
    .onTapGesture { likePost() }
    .monitoorTap("post_liked")
```

### UIKit — `MonitoorButton` subclass

Drop-in replacement for `UIButton`:

```swift
let buyButton = MonitoorButton(eventName: "buy_premium_tapped")
let deleteButton = MonitoorButton(
    eventName: "delete_account_tapped",
    properties: ["source": "settings"]
)
```

### UIKit — extension for existing buttons

Use when you can't change the button class (e.g. third-party views):

```swift
myExistingButton.monitoor_trackTaps(eventName: "sign_in_tapped")
```

---

## Session Duration

The SDK automatically tracks how long each session lasts. When the app goes to the background, a `$app_background` event is sent with a `$session_duration_s` property (seconds as a `Double`).

You can also read the current elapsed session time at any point:

```swift
let seconds = Monitoor.sessionDuration  // e.g. 142.7
```

A new session starts when the app opens, or after the `sessionTimeout` period of background inactivity (default: 30 minutes).

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

Call `startTimer()` when an operation begins. The elapsed time is automatically attached as `$duration` (seconds) when you call `track()` with the same name.

```swift
Monitoor.startTimer("onboarding_flow")

// ... user completes onboarding ...

Monitoor.track("onboarding_flow")
// → event contains "$duration": 47.3
```

---

## Screen Views

> Screen view tracking records only the *name* of the screen — it does not take screenshots, record video, or capture any visual content. The `captureRecordings` option (opt-in, not yet implemented) is the separate feature for actual session recordings.

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

```swift
Monitoor.screen("Custom Screen Name")
```

---

## User Identity

### Identify a user

The SDK is anonymous by default. Call `identify()` after sign-in. The user ID is SHA-256 hashed on-device before transmission — Monitoor never receives the plaintext ID.

```swift
Monitoor.identify(userId: currentUser.id)
```

### Attach user properties

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

### Local buffer

Every event is written synchronously to a SQLite database (`Library/monitoor_buffer.db`) before `track()` returns. This guarantees no events are lost regardless of network state, app kills, or crashes. Events older than `retentionDays` are pruned automatically.

### Flush engine

Events are batched and streamed to the ingest service over HTTPS. The engine drains the buffer in batches of up to `flushBatchSize` events. Flushing is triggered by:

| Trigger | When |
|---|---|
| Batch full | `flushBatchSize` events accumulated |
| App background | `UIApplication.didEnterBackgroundNotification` |
| App terminate | `UIApplication.willTerminateNotification` |
| Timer | Every `flushInterval` seconds |
| Network restored | `NWPathMonitor` path becomes `.satisfied` |

### Retry behaviour

| HTTP response | Action |
|---|---|
| `2xx` | Events deleted from buffer |
| `4xx` client error | Events marked permanently failed, not retried |
| `429` Too Many Requests | Back off for `Retry-After` seconds, retry later |
| `5xx` / network error | Exponential back-off (1s, 2s, 4s … max 5 min), retry |

### Idempotency

Every event carries an `idempotency_key` (`device_id + session_id + timestamp`). The ingest service uses `ON CONFLICT DO NOTHING`, so retried batches never produce duplicate rows.

### Event sampling

When `sampleRate < 1.0`, the SDK randomly discards developer events before they reach the buffer — reducing both data volume and storage usage. System events (those starting with `$`) are always sent regardless of `sampleRate`. The ingest service uses the same multiplier (`mul` on the API key record) for statistical weighting when computing aggregates.

---

## Privacy

| Data | Collected | Notes |
|---|---|---|
| Device ID | Yes | UUID in Keychain — not linked to Apple ID, IDFA, or any real identity |
| IP address | No | Resolved to country server-side, then immediately discarded |
| User ID | Optional | SHA-256 hashed on-device before transmission |
| Screen recordings | No (default) | Opt-in via `captureRecordings: true` — not yet implemented |
| Keystrokes / clipboard | Never | — |
| Precise location | Never | — |
| IDFA / IDFV | Never | No ATT prompt required |
| Push token | Never | — |

The SDK requires **no `NSPrivacyAccessedAPITypes`** entries in `PrivacyInfo.xcprivacy` and triggers no App Tracking Transparency prompt.

---

## FAQ

**How do I get an API key?**
Sign up at [monitoor.io](https://monitoor.io) and generate a key from your project's API Keys section. A CLI-based key creation flow is planned for future releases.

**Does the SDK connect to my database directly?**
No. It only sends HTTPS requests to the ingest service. Database credentials never leave your server.

**What happens when the user is offline?**
Events are buffered in SQLite for up to `retentionDays` days (default: 90). Once connectivity is restored, the buffer drains automatically.

**Can I use the SDK in a SwiftUI preview?**
Yes, but guard the configure call:
```swift
if !ProcessInfo.processInfo.environment.keys.contains("XCODE_RUNNING_FOR_PREVIEWS") {
    Monitoor.configure(apiKey: "mn_dev_...")
}
```

**Can I call `Monitoor.configure()` more than once?**
No. Only the first call takes effect. Subsequent calls are silently ignored.

**How do I verify events are arriving during development?**
Check the Monitoor development dashboard. In DEBUG builds, the SDK also prints `[Monitoor]` log lines to the console.

---

## Troubleshooting

| Symptom | Check |
|---|---|
| No events in dashboard | Verify `apiKey` prefix matches `environment`. Check `[Monitoor]` console logs in DEBUG builds. |
| Fewer events than expected | Check `sampleRate` — if set below `1.0`, events are intentionally dropped client-side. |
| Events appear but are delayed | Default flush interval is 20 s. Call `Monitoor.flush()` for immediate delivery. |
| Crash reports not appearing | Verify `captureCrashes: true`. Crashes upload on the **next** launch, not the crashing one. |
| `mn_live_` key rejected | Ensure `environment: .production` in `MonitoorOptions`. |
| High data usage | Reduce `flushBatchSize` or increase `flushInterval`. Events are gzip-compressed above 1 KB. |
