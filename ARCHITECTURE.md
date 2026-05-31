# MonitoorSDK — Architecture Overview

## System Map

```
┌─────────────────────────────────────────────────────────────────┐
│  iOS Application  (e.g. Nusica)                                 │
│                                                                  │
│   Monitoor.configure(apiKey:, options:)                          │
│   Monitoor.track("event_name", properties: [...])                │
│   Button(...).monitoorTap("event_name")                          │
│   View(...).monitoorScreen("Screen Name")                        │
│                                                                  │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  MonitoorSDK  (Swift Package)                             │  │
│  │                                                           │  │
│  │  Public API ──► MonitoorCore ──► Capture Layer            │  │
│  │                              ──► Buffer Layer             │  │
│  │                              ──► Flush Layer              │  │
│  │                              ──► Core Layer               │  │
│  └──────────────────────────┬────────────────────────────────┘  │
│                             │ HTTP POST /v1/ingest               │
└─────────────────────────────┼───────────────────────────────────┘
                              │
                              ▼
          ┌───────────────────────────────────┐
          │  Ingest Service  (server.py)       │
          │  Python · port 8080               │
          │                                   │
          │  • Authenticates API key          │
          │  • Validates events               │
          │  • Deduplicates via idempotency   │
          └───────────────────┬───────────────┘
                              │ Neon HTTP SQL API
                              ▼
          ┌───────────────────────────────────┐
          │  PostgreSQL  (Neon)               │
          │                                   │
          │  ApiKey  ◄── authentication       │
          │  Event   ◄── all tracked events   │
          │  User    ◄── account ownership    │
          └───────────────────────────────────┘
```

---

## SDK Internal Architecture

### Layer diagram

```
┌──────────────────────────────────────────────────────────────┐
│  Public API  —  Monitoor.swift                               │
│  configure() · track() · screen() · identify() · reset()    │
│  trackRevenue() · startTimer() · flush() · sessionDuration   │
└──────────────────────┬───────────────────────────────────────┘
                       │ delegates everything to
                       ▼
┌──────────────────────────────────────────────────────────────┐
│  MonitoorCore.swift  (internal singleton)                    │
│  Owns and wires all subsystems. Validates key on configure() │
│  Registers UIApplication lifecycle observers                 │
└──┬──────────┬────────────┬──────────────┬────────────────────┘
   │          │            │              │
   ▼          ▼            ▼              ▼
Core      Capture       Buffer         Flush
Layer     Layer         Layer          Layer
```

---

### Core Layer

Provides identity and context that every event carries.

| File | Responsibility |
|---|---|
| `DeviceIdentity.swift` | Generates and persists a UUID `device_id` in the iOS Keychain (`kSecAttrAccessibleAfterFirstUnlock`). Survives app updates; regenerated on `reset()`. |
| `UserIdentity.swift` | Stores optional user identity. SHA-256 hashes the user ID on-device before storing or transmitting — Monitoor never sees plaintext IDs. |
| `SessionManager.swift` | Tracks the current session UUID and start time. Starts a new session after 30 minutes of inactivity (configurable). Exposes `duration` for session length reporting. |
| `DeviceInfo.swift` | Reads `app_version`, `build`, `os`, `device model`, `locale`, `timezone`, and `bundle_id` from the system at startup. Attached to every event as the `context` block. |

---

### Capture Layer

Detects user actions and enqueues them into the buffer.

| File | What it captures | How |
|---|---|---|
| `EventCapture.swift` | All `Monitoor.track()` calls, timed events (`$duration`), button taps | Applies `sampleRate` filter; writes to `LocalBuffer` synchronously; triggers flush when batch is full |
| `ScreenCapture.swift` | Screen views (`$screen_view`) | UIKit: swizzles `UIViewController.viewDidAppear()`. SwiftUI: `.monitoorScreen()` view modifier |
| `ButtonCapture.swift` | Button presses | SwiftUI: `.monitoorTap()` uses `simultaneousGesture(TapGesture())`. UIKit: `MonitoorButton` subclass or `UIButton.monitoor_trackTaps()` via associated-object target |
| `RevenueCapture.swift` | Revenue transactions | StoreKit 2: subscribes to `Transaction.updates`. Manual: `Monitoor.trackRevenue()` |
| `CrashCapture.swift` | App crashes | Installs `NSSetUncaughtExceptionHandler` + `sigaction` for 6 signals. Signal handler uses only async-signal-safe ops (`write()` syscall, no malloc/ObjC). Crash files uploaded on next launch. |

---

### Buffer Layer

Guarantees no event is lost, regardless of network state.

```
track() call
    │ synchronous write (before returning)
    ▼
monitoor_buffer.db   (SQLite, WAL mode, Library directory)
    │
    ├── status = 'pending'   ← waiting to be sent
    ├── status = 'failed'    ← permanently rejected by server (4xx)
    └── pruned after retentionDays (default: 90 days)
```

| File | Responsibility |
|---|---|
| `LocalBuffer.swift` | Thread-safe SQLite wrapper. All reads/writes serialised on a dedicated `DispatchQueue`. Exposes `enqueue`, `dequeue`, `markSent`, `markFailed`, `pruneExpired`. |
| `BufferSchema.swift` | SQLite DDL. WAL journal mode + `NORMAL` sync for crash safety without full fsync on every write. |

The SQLite file is excluded from iCloud backup (`isExcludedFromBackup = true`).

---

### Flush Layer

Drains the buffer over HTTP in a continuous loop.

```
Flush triggered
    │
    ▼
dequeue(limit: 50)  ←── reads from SQLite buffer
    │
    ├── encode to JSON
    ├── gzip compress (if > 1 KB)
    └── POST /v1/ingest
            │
            ├── 2xx  → markSent (delete rows) → fetch next 50 → repeat
            ├── 4xx  → markFailed (permanent, not retried)
            ├── 429  → back off for Retry-After seconds
            └── 5xx / network error → exponential backoff (1s → 2s → 4s → max 300s)
```

**Flush triggers** (all active simultaneously):

| Trigger | Condition |
|---|---|
| Timer | Every `flushInterval` seconds (default: 20s) |
| Batch full | When pending count reaches `flushBatchSize` (default: 50) |
| App backgrounds | `UIApplication.didEnterBackgroundNotification` — uses a background task to finish |
| App terminates | `UIApplication.willTerminateNotification` — synchronous flush, 3s deadline |
| Network restored | `NWPathMonitor` path becomes `.satisfied` |

| File | Responsibility |
|---|---|
| `FlushEngine.swift` | Owns the timer, network monitor, lifecycle observers, and the drain loop. |
| `HTTPClient.swift` | URLSession wrapper. Sends `POST /v1/ingest` and `POST /v1/crashes`. Parses `IngestResponse`. |
| `BatchEncoder.swift` | JSON-encodes `IngestBatch`. gzip-compresses payloads > 1 KB using the system Compression framework. |

---

### Models

| File | Types defined |
|---|---|
| `Event.swift` | `BufferedEvent`, `BufferRowType`, `EventContext`, `WireEvent`, `PendingEvent`, `AnyCodable` |
| `Batch.swift` | `IngestBatch`, `IngestResponse`, `IngestError`, `OutboundBatch` |
| `CrashReport.swift` | `CrashReport`, `CrashThread`, `CrashFrame`, `CrashResponse` |

---

## Wire Format

Every flush sends a single HTTP request:

```
POST {ingestURL}/v1/ingest
Authorization: Bearer mn_dev_…  (or mn_live_…)
Content-Type: application/json
Content-Encoding: gzip          (when payload > 1 KB)
X-Monitoor-SDK-Version: 1.0.0

{
  "sdk_version": "1.0.0",
  "batch": [
    {
      "type": "event",
      "name": "play_pause_tapped",
      "session_id": "uuid",
      "device_id": "uuid",
      "user_id_hash": "sha256hex | null",
      "idempotency_key": "device_id-session_id-occurred_at_ms",
      "occurred_at": "2026-05-31T12:00:00.000Z",
      "properties": { "source": "mini_player" },
      "context": {
        "app_version": "1.0",
        "build": "1",
        "os": "iOS 18.0",
        "device": "iPhone 16 Pro",
        "locale": "en_US",
        "timezone": "Europe/London",
        "bundle_id": "com.example.app"
      }
    }
  ]
}
```

**Response:**

```json
{ "accepted": 49, "rejected": 1, "errors": [{ "index": 12, "reason": "occurred_at is in the future" }] }
```

Partial acceptance: valid events are stored even if some in the batch are rejected.

---

## Idempotency

Every event carries an `idempotency_key` composed of:

```
{device_id} - {session_id} - {occurred_at_ms}
```

The ingest server inserts with `ON CONFLICT ("idempotencyKey") DO NOTHING`. If the network drops after the server writes but before it responds, the SDK retries the same batch — duplicates are silently dropped.

---

## Privacy Model

| Data | Behaviour |
|---|---|
| `device_id` | UUID generated on first launch, stored in Keychain. Not linked to Apple ID, IDFA, or any real identity. |
| `user_id` | SHA-256 hashed on-device before storage or transmission. Monitoor stores only the hash. |
| IP address | Used server-side to resolve country, then immediately discarded. Never stored. |
| Screen recordings | Off by default. Opt-in via `captureRecordings: true`. Not yet implemented. |
| Heatmaps | Off by default. Opt-in via `captureHeatmaps: true`. Not yet implemented. |
| IDFA / IDFV | Never collected. No ATT prompt required. |

---

## Configuration Reference

All settings in `MonitoorOptions` mirror columns on the `ApiKey` database record:

| Option | DB column | Default | Notes |
|---|---|---|---|
| `environment` | `env` | `.production` | Must match key prefix (`mn_live_` / `mn_dev_`) |
| `captureEvents` | `captureEvents` | `true` | |
| `captureScreens` | `captureScreens` | `true` | UIKit: automatic. SwiftUI: `.monitoorScreen()` |
| `captureRevenue` | `captureRevenue` | `true` | StoreKit 2 automatic |
| `captureCrashes` | `captureCrashes` | `true` | |
| `captureHeatmaps` | `captureHeatmaps` | `false` | Opt-in |
| `captureRecordings` | `captureRecordings` | `false` | Opt-in |
| `sampleRate` | `mul` | `1.0` | 0.0–1.0. System `$` events are never sampled out. |
| `retentionDays` | `retention` | `90` | Max age of unsent events in local buffer |
| `flushInterval` | — | `20s` | |
| `flushBatchSize` | — | `50` | |
| `sessionTimeout` | — | `30 min` | Inactivity before new session |

---

## Key Format

```
mn_live_{48 hex chars}   — production
mn_dev_{48 hex chars}    — development
```

The SDK validates the prefix against `environment` at `configure()` time and refuses to start if they don't match. The ingest server authenticates by looking up `keyValue` in the `ApiKey` table.

---

## Database Schema (Neon PostgreSQL)

```
ApiKey
  id · userId · name · env · keyValue · partial
  appName · bundleId · artworkUrl
  captureEvents · captureScreens · captureCrashes
  captureRevenue · captureHeatmaps · captureRecordings
  mul (sampleRate) · retention · lastUsedAt
  createdAt · updatedAt

Event
  id · apiKeyId (FK → ApiKey) · name · properties (JSONB)
  sessionId · deviceId · userIdHash · idempotencyKey (UNIQUE)
  appVersion · osVersion · deviceModel · bundleId · appName
  environment · occurredAt · receivedAt

User
  (account ownership — managed by the dashboard)
```

Indexes on `Event`: `(apiKeyId, name, occurredAt DESC)`, `(apiKeyId, deviceId, occurredAt DESC)`, `GIN(properties)`, `UNIQUE(idempotencyKey)`.

---

## Repository Layout

```
monitoor-sdk/                    ← planning & ingest server repo
  SDK.md                         ← full design spec
  PLAN.md                        ← implementation plan
  ARCHITECTURE.md                ← this file
  ingest-server/
    server.py                    ← Python ingest service
    .env                         ← credentials (gitignored)
    .env.example                 ← safe template (tracked)

monitoor-ios-sdk/                ← Swift Package (separate repo)
  Package.swift
  Sources/MonitoorSDK/
    Monitoor.swift               ← entire public API
    MonitoorOptions.swift        ← configuration
    MonitoorCore.swift           ← internal wiring singleton
    Core/
      DeviceIdentity.swift
      SessionManager.swift
      UserIdentity.swift
      DeviceInfo.swift
    Capture/
      EventCapture.swift
      ScreenCapture.swift
      ButtonCapture.swift
      RevenueCapture.swift
      CrashCapture.swift
    Buffer/
      LocalBuffer.swift
      BufferSchema.swift
    Flush/
      FlushEngine.swift
      HTTPClient.swift
      BatchEncoder.swift
    Models/
      Event.swift
      Batch.swift
      CrashReport.swift
  Tests/MonitoorSDKTests/
    BufferTests.swift
    SessionTests.swift
    AuthTests.swift
    UserIdentityTests.swift
    BatchEncoderTests.swift
```
