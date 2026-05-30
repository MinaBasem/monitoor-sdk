# Monitoor iOS SDK — Proof of Concept

This document outlines the complete design of the Monitoor iOS SDK: how it initializes, how it links to an app and user account, how each data type is captured, how batches stream to the backend, and how the backend stores everything in PostgreSQL. It also documents known gaps and the reasoning behind each design decision.

---

## 1. High-Level Architecture

```
iOS App
  └── MonitoorSDK
        ├── Capture layer     (events, crashes, screens, revenue, clicks)
        ├── Local buffer      (SQLite WAL queue — survives app kills and network loss)
        ├── Flush engine      (batch streaming on interval / trigger)
        └── HTTP client       (HTTPS POST to Monitoor Ingest Service)

                          ┌─────────────────────────────────┐
                          │  EC2 Instance (or localhost)     │
                          │                                  │
                          │  Ingest Service (thin HTTP API)  │
                          │    ↓  authenticates key          │
                          │  PgBouncer (connection pool)     │
                          │    ↓  pools connections          │
                          │  PostgreSQL                      │
                          └─────────────────────────────────┘
```

### Why the SDK does not connect directly to PostgreSQL

This is a critical design decision. Connecting an iOS app directly to Postgres using a native driver is technically possible but creates severe problems:

| Problem | Impact |
|---|---|
| **Credentials in the app bundle** | Any user can extract the DB host, port, username, and password from the IPA. They get unrestricted database access. |
| **No connection limits** | Postgres has a hard `max_connections` ceiling (typically 100–200). 10,000 active users = 10,000 open TCP connections = the database crashes. |
| **No rate limiting** | A single device can flood the database with millions of inserts per minute. |
| **No request validation** | Malformed or malicious payloads write directly to your tables. |
| **Mobile network instability** | Postgres TCP connections drop constantly on 4G/5G handoffs. The native driver has no retry or buffering logic. |

**The solution:** a thin ingest service on the same EC2 instance (or `localhost` for testing) that sits between the SDK and Postgres. It handles auth, validation, rate limiting, and uses PgBouncer to multiplex many SDK connections into a small pool of actual Postgres connections.

---

## 2. Environments: EC2 vs Local

The SDK accepts an `ingestURL` parameter so developers can point it at a local Postgres setup during development without changing any other code.

```swift
// Production (EC2)
Monitoor.configure(
  apiKey: "mn_live_••••••••••••••••",
  options: MonitoorOptions(
    ingestURL: URL(string: "https://ingest.monitoor.io")!,
    environment: .production
  )
)

// Local development (laptop running Postgres + ingest service)
Monitoor.configure(
  apiKey: "mn_dev_••••••••••••••••",
  options: MonitoorOptions(
    ingestURL: URL(string: "http://localhost:8080")!,
    environment: .development
  )
)
```

### Local setup

The ingest service is a standalone HTTP server (a small Go or Node.js binary, or even a Python FastAPI app) that runs on the developer's machine alongside a local Postgres instance. The SDK behaviour is identical in both environments — only `ingestURL` and the key prefix differ.

```
Developer laptop
  ├── Xcode Simulator (iOS app + MonitoorSDK)
  │     └── HTTP → localhost:8080
  ├── Monitoor Ingest Service  (localhost:8080)
  │     └── connects to → localhost:5432
  └── PostgreSQL  (localhost:5432)
```

The development API key (`mn_dev_`) maps to a separate row in `api_keys` with `environment = 'development'`. Events from dev keys are stored in the same schema but tagged `environment = 'development'` so they can be filtered out of production dashboards.

---

## 3. API Key & App Linking — Complete Chain

This section traces the full chain from a user account down to a single event row.

### Entity relationships

```
organizations          ← a company or individual developer account
  └── apps             ← one record per iOS app (identified by App Store ID)
        └── api_keys   ← one or more keys per app (prod + dev)
              └── [ingest request authenticated] → events, sessions, crashes, revenue
```

### Step-by-step: how a key is created

1. Developer signs up → an `organizations` row is created.
2. Developer adds an app in the dashboard:
   - Enters **App name** (display only)
   - Enters **App Store ID** (numeric Apple ID, e.g. `6450454949`) — this is the canonical app identifier. It is immutable and globally unique on Apple's platform.
   - Selects **Environment**: `production` or `development`
3. Dashboard generates a key:
   - **Plaintext** (shown once): `mn_live_a3f8b2c4d5e6f7g8h9i0j1k2l3m4n9x2k`
   - **Prefix** (stored for display): `mn_live_a3f8...9x2k`
   - **Hash** (stored in DB): `bcrypt(plaintext, cost=12)`
4. Developer copies the plaintext key into their Xcode project.

### How a request is authenticated

```
SDK sends:
  POST /v1/ingest
  Authorization: Bearer mn_live_a3f8b2c4d5e6f7g8h9i0j1k2l3m4n9x2k

Ingest service:
  1. Parse prefix from key → determine it is a 'production' key
  2. bcrypt.compare(incomingKey, row.key_hash) for all non-revoked keys
     ⚠ bcrypt is slow — see §13 Gap: Key Lookup Performance
  3. Confirm revoked_at IS NULL
  4. Read app_id from the matched api_keys row
  5. Read org_id from apps WHERE id = app_id
  6. UPDATE api_keys SET last_used_at = NOW() WHERE id = ...
  7. Tag all events in the batch with app_id, then INSERT
```

Every event, session, crash, and revenue row is tagged with `app_id`. The dashboard queries always filter by `app_id`, so one Postgres instance safely serves multiple customers.

### Database tables

```sql
CREATE TABLE organizations (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL,
  email       TEXT NOT NULL UNIQUE,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE apps (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id        UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  app_store_id  TEXT NOT NULL UNIQUE,   -- Apple numeric ID, e.g. "6450454949"
  bundle_id     TEXT,                   -- com.example.app, populated on first ingest
  platform      TEXT NOT NULL DEFAULT 'ios',
  created_at    TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE api_keys (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id        UUID NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  key_hash      TEXT NOT NULL UNIQUE,   -- bcrypt hash, cost 12
  key_prefix    TEXT NOT NULL,          -- "mn_live_a3f8...9x2k" for display only
  environment   TEXT NOT NULL CHECK (environment IN ('production', 'development')),
  label         TEXT,                   -- optional human name, e.g. "CI key"
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  last_used_at  TIMESTAMPTZ,
  revoked_at    TIMESTAMPTZ             -- soft delete
);
```

---

## 4. SDK Initialization

```swift
import MonitoorSDK

@main
struct FolioApp: App {
  init() {
    Monitoor.configure(
      apiKey: "mn_live_••••••••••••••••",
      options: MonitoorOptions(
        ingestURL: URL(string: "https://ingest.monitoor.io")!,
        captureEvents: true,
        captureScreenViews: true,
        captureRevenue: true,
        captureCrashes: true,
        captureClickHeatmaps: false,    // opt-in; privacy-sensitive
        captureSessionRecordings: false, // opt-in; privacy-sensitive
        environment: .production,
        flushInterval: 20,              // seconds between scheduled flushes
        flushBatchSize: 50,             // max events per HTTP request
        maxBufferAge: 72 * 3600         // drop unsent events after 72 hours
      )
    )
  }

  var body: some Scene {
    WindowGroup { ContentView() }
  }
}
```

On `configure()`, the SDK:
1. Validates the key format and environment consistency (`mn_live_` must pair with `.production`, `mn_dev_` with `.development`). Logs a warning and refuses to start if mismatched.
2. Creates or loads a persistent `device_id` (UUID in Keychain, `kSecAttrAccessibleAfterFirstUnlock`).
3. Opens the local SQLite buffer (`monitoor_buffer.db`) in WAL mode.
4. Installs crash handlers (§7).
5. Installs StoreKit observer if `captureRevenue: true` (§9).
6. Registers `NWPathMonitor` to trigger flushes when connectivity is restored.
7. Schedules the flush timer.
8. Enqueues an `$app_open` event.

---

## 5. User & Session Model

### Identity

The SDK is anonymous-first. No PII is collected by default.

```
device_id   — UUID stored in Keychain. Stable across app updates.
              Regenerated on fresh install if iCloud Keychain is off.

user_id_hash — Optional. Developer calls Monitoor.identify(userId:).
               The SDK SHA-256 hashes the string before storing or transmitting it.
               Monitoor never sees the plaintext user ID.
```

```swift
// Link your own user ID (hashed before transmission)
Monitoor.identify(userId: currentUser.id)

// Attach non-PII properties
Monitoor.setUserProperties([
  "plan": "pro",
  "account_age_days": 120
])

// Clear on sign-out
Monitoor.reset()  // generates a new device_id, clears user_id_hash
```

### Sessions

A session begins on `$app_open` or foreground transition and ends after **30 minutes of inactivity** or an explicit `$app_background` event. The session ID is a UUID generated at session start and attached to every event for that session.

```sql
CREATE TABLE sessions (
  id            UUID PRIMARY KEY,           -- generated by SDK, sent in payload
  app_id        UUID NOT NULL REFERENCES apps(id),
  device_id     TEXT NOT NULL,
  user_id_hash  TEXT,
  started_at    TIMESTAMPTZ NOT NULL,
  ended_at      TIMESTAMPTZ,
  duration_s    INT,
  device_model  TEXT,                       -- "iPhone 15 Pro"
  os_version    TEXT,                       -- "iOS 17.4"
  app_version   TEXT,                       -- "2.1.0"
  build         TEXT,                       -- "214"
  environment   TEXT NOT NULL,
  country       TEXT,                       -- resolved from IP server-side, then IP discarded
  received_at   TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_sessions_app_device ON sessions (app_id, device_id, started_at DESC);
```

---

## 6. Event Streaming

### Capture

```swift
// Simple event
Monitoor.track("button_tapped")

// Event with properties
Monitoor.track("portfolio_created", properties: [
  "asset_count": 5,
  "template": "growth"
])

// Timed event — duration is auto-attached on the closing call
Monitoor.startTimer("onboarding_flow")
Monitoor.track("onboarding_completed")
```

### Local buffer (write path)

Every `track()` call writes synchronously to the local SQLite buffer before returning. This guarantees no event is lost regardless of network state, app kills, or crashes.

```sql
-- SDK-side SQLite schema (on device)
CREATE TABLE buffer (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  payload     TEXT NOT NULL,        -- JSON-encoded event
  created_at  INTEGER NOT NULL,     -- Unix timestamp (ms)
  attempts    INTEGER DEFAULT 0,
  status      TEXT DEFAULT 'pending' -- 'pending' | 'failed'
);
```

### Flush (stream path)

Events are streamed to the ingest service in batches. "Streaming" here means: the SDK continuously drains its local buffer over HTTP as events accumulate, rather than waiting for a single large upload.

**Flush triggers (in priority order):**
1. `flushBatchSize` reached (default: 50 events) — immediate flush
2. App moves to background (`sceneWillResignActive`) — flush all pending
3. App will terminate (`applicationWillTerminate`) — synchronous flush, 3s deadline
4. Timer fires (default: every 20 seconds)
5. Network restored (`NWPathMonitor` path becomes `.satisfied`)

**Flush algorithm:**

```
loop:
  rows = SELECT * FROM buffer WHERE status = 'pending' ORDER BY id LIMIT 50
  if rows is empty → stop

  compress rows as gzip JSON
  response = POST /v1/ingest (with compressed payload)

  if response is 2xx:
    DELETE FROM buffer WHERE id IN (rows)
    continue loop   ← immediately fetch and send the next batch

  if response is 4xx (client error — bad key, malformed event):
    UPDATE buffer SET status = 'failed' WHERE id IN (rows)
    stop  ← do not retry; these events are permanently rejected

  if response is 5xx or network error:
    attempts += 1
    wait = min(2^attempts * 1s, 300s)  ← exponential backoff, max 5 minutes
    stop  ← retry on next trigger
```

This loop means if 5,000 events are buffered (e.g. after extended offline use), the SDK sends them in 100 consecutive batches of 50, draining the queue as fast as the network allows.

### Wire format

```json
{
  "sdk_version": "1.0.0",
  "batch": [
    {
      "type":       "event",
      "name":       "portfolio_created",
      "session_id": "550e8400-e29b-41d4-a716-446655440000",
      "device_id":  "a1b2c3d4-...",
      "idempotency_key": "a1b2c3d4-550e8400-1717070581234",
      "occurred_at": "2026-05-30T14:23:01.234Z",
      "properties": {
        "asset_count": 5,
        "template": "growth"
      },
      "context": {
        "app_version": "2.1.0",
        "build":       "214",
        "os":          "iOS 17.4",
        "device":      "iPhone 15 Pro",
        "locale":      "en_US",
        "timezone":    "America/Los_Angeles",
        "bundle_id":   "com.example.folio"
      }
    }
  ]
}
```

The `idempotency_key` is `device_id + session_id + occurred_at (ms)`. The ingest service uses this to deduplicate retried batches (see §13 Gap: Duplicate Events).

### Database schema

```sql
CREATE TABLE events (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id           UUID NOT NULL REFERENCES apps(id),
  session_id       UUID REFERENCES sessions(id),
  device_id        TEXT NOT NULL,
  user_id_hash     TEXT,
  name             TEXT NOT NULL,
  properties       JSONB,
  idempotency_key  TEXT UNIQUE,     -- prevents duplicate inserts on retry
  app_version      TEXT,
  os_version       TEXT,
  device_model     TEXT,
  bundle_id        TEXT,
  environment      TEXT NOT NULL,
  occurred_at      TIMESTAMPTZ NOT NULL,
  received_at      TIMESTAMPTZ DEFAULT NOW()
) PARTITION BY RANGE (occurred_at);   -- see §12 for partitioning

CREATE INDEX idx_events_app_name_time  ON events (app_id, name, occurred_at DESC);
CREATE INDEX idx_events_app_device     ON events (app_id, device_id, occurred_at DESC);
CREATE INDEX idx_events_properties     ON events USING GIN (properties);
CREATE UNIQUE INDEX idx_events_idem    ON events (idempotency_key)
  WHERE idempotency_key IS NOT NULL;
```

---

## 7. Crash Detection

### Handlers installed on init

1. `NSSetUncaughtExceptionHandler` — catches ObjC/Swift exceptions.
2. `sigaction` — catches signals: `SIGABRT`, `SIGSEGV`, `SIGBUS`, `SIGILL`, `SIGFPE`, `SIGTRAP`.

### Crash flow

```
1. Crash occurs on any thread
2. Signal/exception handler fires on the crashing thread
3. Handler performs only async-signal-safe operations:
     - Captures thread backtraces (backtrace())
     - Writes a crash report file to Library/Caches/monitoor_crashes/
       (mmap + write syscall — no malloc, no ObjC)
4. Process exits
5. On NEXT app launch:
     - SDK scans for pending crash files
     - Uploads each to POST /v1/crashes before sending any other events
     - Deletes the file on 2xx response
```

### Crash payload

```json
{
  "type":          "crash",
  "idempotency_key": "device_id-crash-timestamp",
  "exception_type":  "EXC_BAD_ACCESS",
  "exception_name":  "SIGSEGV",
  "reason":          "KERN_INVALID_ADDRESS at 0x0000000000000000",
  "app_version":     "2.1.0",
  "build":           "214",
  "os_version":      "iOS 17.4",
  "device":          "iPhone 15 Pro",
  "session_id":      "550e8400-...",
  "device_id":       "a1b2c3d4-...",
  "occurred_at":     "2026-05-30T14:23:01.234Z",
  "threads": [
    {
      "index":   0,
      "crashed": true,
      "frames": [
        { "index": 0, "image": "Folio",     "address": "0x000000010045a3bc", "offset": 1234 },
        { "index": 1, "image": "Folio",     "address": "0x000000010045a200", "offset": 512  },
        { "index": 2, "image": "UIKitCore", "address": "0x00000001a234b000", "offset": 8192 }
      ]
    }
  ]
}
```

Symbols are resolved server-side using uploaded dSYM files (`atos`). Unsymbolicated frames show raw addresses until the dSYM is uploaded.

### Severity (server-side classification)

| Signal / Exception | Severity |
|---|---|
| `SIGSEGV`, `SIGBUS`, `EXC_BAD_ACCESS` | Critical |
| `SIGABRT` (fatalError, assert) | High |
| Uncaught `NSException` | High |
| `SIGILL` | Medium |
| All others | Low |

### Database schema

```sql
CREATE TABLE crashes (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id           UUID NOT NULL REFERENCES apps(id),
  fingerprint      TEXT NOT NULL,    -- SHA-256 of normalized top-5 frame addresses
  name             TEXT NOT NULL,
  reason           TEXT,
  severity         TEXT CHECK (severity IN ('critical', 'high', 'medium', 'low')),
  status           TEXT DEFAULT 'open' CHECK (status IN ('open', 'resolved', 'ignored')),
  app_version      TEXT,
  os_version       TEXT,
  device_model     TEXT,
  first_seen_at    TIMESTAMPTZ,
  last_seen_at     TIMESTAMPTZ,
  occurrence_count INT DEFAULT 1,
  affected_users   INT DEFAULT 1,
  raw_report       JSONB,
  symbolicated     BOOLEAN DEFAULT FALSE,
  idempotency_key  TEXT UNIQUE,
  environment      TEXT NOT NULL,
  created_at       TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_crashes_app_fingerprint ON crashes (app_id, fingerprint);
CREATE INDEX idx_crashes_open            ON crashes (app_id, severity, last_seen_at DESC)
  WHERE status = 'open';
```

Duplicate crashes (matching `fingerprint`) increment `occurrence_count` and update `last_seen_at` via an `ON CONFLICT` upsert, not a new row.

---

## 8. Screen View Tracking

### UIKit (automatic)

The SDK swizzles `UIViewController.viewDidAppear(_:)` at `configure()` time. The screen name is derived from the class name with common suffixes stripped (`ViewController`, `VC`, `Controller`).

### SwiftUI (manual modifier)

```swift
struct PortfolioView: View {
  var body: some View {
    List { ... }
      .monitoorScreen("Portfolio Detail", properties: ["symbol": "AAPL"])
  }
}
```

### Wire format

Screen views are sent as regular events with `name: "$screen_view"` and a `$screen_name` property. No separate table is needed.

---

## 9. Revenue Tracking (StoreKit)

### StoreKit 2 (automatic)

```swift
// SDK subscribes to Transaction.updates internally — no developer code required
for await result in Transaction.updates {
  if case .verified(let tx) = result {
    // SDK reads: productID, price, currency, transactionID, purchaseDate
    Monitoor.internal_trackTransaction(tx)
  }
}
```

### StoreKit 1 / manual

```swift
Monitoor.trackRevenue(
  productId: "com.folio.premium_annual",
  amount:    49.99,
  currency:  "USD",
  type:      .subscription,
  transactionId: payment.transaction.transactionIdentifier
)
```

### Database schema

```sql
CREATE TABLE revenue_events (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id          UUID NOT NULL REFERENCES apps(id),
  session_id      UUID,
  device_id       TEXT,
  user_id_hash    TEXT,
  product_id      TEXT NOT NULL,
  amount_usd      NUMERIC(10, 4),     -- normalized to USD by ingest service
  currency        TEXT,
  original_amount NUMERIC(10, 4),
  transaction_id  TEXT NOT NULL,
  type            TEXT CHECK (type IN ('subscription', 'one_time', 'consumable')),
  environment     TEXT NOT NULL,
  app_version     TEXT,
  occurred_at     TIMESTAMPTZ NOT NULL,
  received_at     TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (app_id, transaction_id)     -- deduplication at DB level
);

CREATE INDEX idx_revenue_app_occurred ON revenue_events (app_id, occurred_at DESC);
```

MRR, ARR, and ARPU are computed at query time. They are not stored as materialized values, which keeps the schema simple but requires efficient indexes (added above).

---

## 10. Funnel Tracking

Funnels are defined in the Monitoor dashboard — not in the SDK. The SDK only tracks events. The backend computes funnel steps by finding devices/users that performed step A, then step B, then step C within a configurable time window, in order.

Example query for a 4-step onboarding funnel:

```sql
WITH step1 AS (
  SELECT DISTINCT device_id FROM events
  WHERE app_id = $1 AND name = 'app_open' AND occurred_at > NOW() - INTERVAL '30 days'
),
step2 AS (
  SELECT DISTINCT e.device_id FROM events e
  JOIN step1 s ON e.device_id = s.device_id
  WHERE e.app_id = $1 AND e.name = 'onboarding_started'
),
step3 AS (
  SELECT DISTINCT e.device_id FROM events e
  JOIN step2 s ON e.device_id = s.device_id
  WHERE e.app_id = $1 AND e.name = 'portfolio_created'
),
step4 AS (
  SELECT DISTINCT e.device_id FROM events e
  JOIN step3 s ON e.device_id = s.device_id
  WHERE e.app_id = $1 AND e.name = 'subscription_started'
)
SELECT
  (SELECT COUNT(*) FROM step1) AS step1_count,
  (SELECT COUNT(*) FROM step2) AS step2_count,
  (SELECT COUNT(*) FROM step3) AS step3_count,
  (SELECT COUNT(*) FROM step4) AS step4_count;
```

---

## 11. Ingest Service (Backend)

The ingest service is a stateless HTTP server running on the same EC2 instance as Postgres (or on localhost for local dev). It has no business logic beyond authentication, validation, and writing.

### Endpoints

#### `POST /v1/ingest`

```
Authorization: Bearer <api_key>
Content-Type: application/json
Content-Encoding: gzip
X-Monitoor-SDK-Version: 1.0.0
```

**Processing:**
1. Authenticate key (see §3).
2. Decompress payload.
3. Validate schema (required fields: `name`, `occurred_at`, `device_id`, `session_id`).
4. Reject events with `occurred_at` more than 24 hours in the future (clock skew protection — see §13).
5. Bulk insert valid events using `INSERT ... ON CONFLICT (idempotency_key) DO NOTHING`.
6. Return:

```json
{ "accepted": 47, "rejected": 1, "errors": [{ "index": 12, "reason": "missing occurred_at" }] }
```

Partial acceptance: valid events are stored even if some rows in the batch are malformed.

#### `POST /v1/crashes`

Same auth. Single crash report. Returns:

```json
{ "crash_id": "uuid", "symbolicated": false }
```

Symbolication is deferred to an async background worker.

#### `GET /health`

Returns `200 OK` with no auth required. Used by EC2 health checks and local test scripts.

### PgBouncer (connection pooling)

Postgres opens a new OS process per connection. Without pooling, 500 concurrent SDK flushes = 500 Postgres processes = degraded performance or crash. PgBouncer sits between the ingest service and Postgres, maintaining a small pool of real connections (e.g. 20) and queuing ingest service requests against them.

```
Ingest service → PgBouncer (pool of 20) → PostgreSQL
```

For local development, PgBouncer can be omitted — the ingest service connects directly to Postgres.

---

## 12. PostgreSQL Schema — Full Picture

### Entity hierarchy

```
organizations
  └── apps (org_id FK)
        ├── api_keys      (app_id FK)
        ├── sessions       (app_id FK)
        │     └── events  (app_id FK, session_id FK)
        ├── crashes        (app_id FK)
        └── revenue_events (app_id FK)
```

### Table partitioning (events at scale)

The `events` table is the only one that will grow to billions of rows. Partition it by month from the start — adding partitioning later requires a table rewrite.

```sql
CREATE TABLE events (
  -- columns as defined in §6
) PARTITION BY RANGE (occurred_at);

-- Create partitions ahead of time (automate with a cron job)
CREATE TABLE events_2026_05 PARTITION OF events
  FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');

CREATE TABLE events_2026_06 PARTITION OF events
  FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
```

Old partitions can be dropped instantly (`DROP TABLE events_2024_01`) for data retention enforcement — far faster than `DELETE`.

### Key indexes (all tables)

```sql
-- events
CREATE INDEX ON events (app_id, name, occurred_at DESC);
CREATE INDEX ON events (app_id, device_id, DATE(occurred_at));
CREATE INDEX ON events USING GIN (properties);

-- sessions
CREATE INDEX ON sessions (app_id, device_id, started_at DESC);

-- crashes
CREATE INDEX ON crashes (app_id, fingerprint);
CREATE INDEX ON crashes (app_id, severity, last_seen_at DESC) WHERE status = 'open';

-- revenue
CREATE INDEX ON revenue_events (app_id, occurred_at DESC);
CREATE INDEX ON revenue_events (app_id, product_id);
```

---

## 13. Gaps, Issues & Fixes

These are problems with the original design that are addressed in this revision.

---

### Gap 1: Direct database connection from the SDK

**Problem:** An iOS app connecting directly to Postgres embeds database credentials in the app bundle, which can be extracted from any IPA. The attacker gets full database access.

**Fix:** The SDK connects only to an HTTP ingest service. The service holds the Postgres credentials server-side, never exposed to the client. Addressed in §1 and §11.

---

### Gap 2: No connection pooling

**Problem:** Postgres `max_connections` defaults to 100. A modestly popular app with 500 concurrent users flushing events simultaneously kills the database.

**Fix:** PgBouncer in transaction-mode pooling between the ingest service and Postgres. Pool size of 20–50 real connections handles thousands of concurrent HTTP requests. Addressed in §11.

---

### Gap 3: bcrypt key lookup is O(n) and slow

**Problem:** To authenticate a key, the original design hashes the incoming key with bcrypt and scans `api_keys`. bcrypt is intentionally slow (~100ms per comparison). With many keys in the table, this is expensive on every request.

**Fix:** Use a two-phase lookup:
1. Store a fast lookup token alongside the bcrypt hash: `SHA-256(plaintext_key)`, indexed.
2. On ingest: compute `SHA-256(incoming_key)` (fast, microseconds), look up by `key_sha256` (indexed), then verify with bcrypt only once to confirm (or skip bcrypt entirely and rely on SHA-256 + the indexed unique constraint, which is cryptographically sufficient for a bearer token).

```sql
ALTER TABLE api_keys ADD COLUMN key_sha256 TEXT UNIQUE NOT NULL;
CREATE INDEX ON api_keys (key_sha256) WHERE revoked_at IS NULL;
```

Lookup becomes: `SELECT * FROM api_keys WHERE key_sha256 = $1 AND revoked_at IS NULL`.

---

### Gap 4: No rate limiting

**Problem:** Without rate limiting, a single device or a malicious actor can flood the ingest endpoint with millions of requests, exhausting the database write capacity and running up your EC2 costs.

**Fix:** Rate limit by API key at the ingest service layer:
- Max **1,000 events per device per hour** (configurable per plan).
- Max **100 HTTP requests per key per minute**.
- Implement in-memory (or Redis/Postgres-backed) sliding window counters.
- Return `429 Too Many Requests` with a `Retry-After` header. The SDK backs off and retries.

---

### Gap 5: Duplicate events on retry

**Problem:** If the network drops after the ingest service writes to Postgres but before it returns `200` to the SDK, the SDK will retry the same batch. Without deduplication, you get double-counted events.

**Fix:** Every event carries an `idempotency_key` (`device_id + session_id + occurred_at_ms`). The ingest service uses:

```sql
INSERT INTO events (...) VALUES (...)
ON CONFLICT (idempotency_key) DO NOTHING;
```

Retried events silently no-op. Addressed in §6.

---

### Gap 6: Clock skew on device

**Problem:** Mobile device clocks can be wrong by hours or days (airplane mode, time zone changes, manual clock). An `occurred_at` far in the future corrupts time-series charts. An `occurred_at` years in the past is useless.

**Fix:** The ingest service rejects events where:
- `occurred_at > server_time + 5 minutes` (future events)
- `occurred_at < server_time - 7 days` (stale events beyond the buffer window)

The SDK also records `received_at` (server timestamp) on every row so dashboards can detect and compensate for skew if needed.

---

### Gap 7: No data retention / deletion mechanism

**Problem:** GDPR and App Store privacy requirements mandate that users can request deletion of their data. There is no mechanism to delete events by `device_id`.

**Fix:** Add a soft-delete path:

```sql
-- "Forget this device" — called when user requests data deletion
DELETE FROM events        WHERE app_id = $1 AND device_id = $2;
DELETE FROM sessions      WHERE app_id = $1 AND device_id = $2;
DELETE FROM revenue_events WHERE app_id = $1 AND device_id = $2;
-- crashes are not linked to device_id directly (aggregated) — no action needed
```

Because `device_id` is a UUID with no link to Apple ID or real identity, this satisfies the legal requirement without knowing who the user actually is. Add an index on `device_id` for all high-volume tables so these deletes are fast.

---

### Gap 8: No dSYM upload mechanism documented

**Problem:** Crash frames are uploaded as raw memory addresses. Without the dSYM file (the debug symbol map), every crash in the dashboard shows `???` instead of function names and line numbers.

**Fix:** Add a dSYM upload endpoint:

```
POST /v1/apps/:app_id/dsym
Content-Type: multipart/form-data

Fields: file (the .dSYM zip), build_uuid, app_version, build_number
```

The ingest service stores the dSYM file on disk (or S3). A background worker picks up unsymbolicated crash rows, runs `atos -arch arm64 -o <dsym> -l <load_addr> <frame_addr>` for each frame, updates `crashes.raw_report` with resolved symbols, and sets `symbolicated = TRUE`.

```sql
CREATE TABLE dsyms (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id       UUID NOT NULL REFERENCES apps(id),
  build_uuid   TEXT NOT NULL UNIQUE,  -- matches LC_UUID in the binary
  app_version  TEXT NOT NULL,
  build        TEXT NOT NULL,
  file_path    TEXT NOT NULL,         -- path on disk or S3 key
  uploaded_at  TIMESTAMPTZ DEFAULT NOW()
);
```

---

### Gap 9: Session end is unreliable

**Problem:** `applicationWillTerminate` is not guaranteed to be called on iOS (force-quit, OOM kill, crash). Sessions can remain open in the database indefinitely.

**Fix:** Two complementary approaches:
1. **SDK:** On next `$app_open`, if the SDK finds a session that started in a previous process, it synthesizes a `$session_end` event with `ended_at = last_event_occurred_at + 1s` before starting the new session.
2. **Backend:** A nightly job closes any sessions where `ended_at IS NULL AND started_at < NOW() - INTERVAL '2 hours'` by setting `ended_at = last known event for that session`.

---

## 14. Privacy & Compliance

| Data point | Collected | Notes |
|---|---|---|
| Device ID | Yes | UUID in Keychain — not linked to Apple ID, IDFA, or real identity |
| IP address | Transient server-side only | Used to resolve country, then immediately discarded; never stored |
| User ID | Optional, hashed | SHA-256 client-side before transmission; Monitoor stores only the hash |
| Screen recordings | No (default) | Explicit opt-in in `MonitoorOptions` |
| Keystrokes / clipboard | Never | — |
| Precise location | Never | — |
| IDFA / IDFV | Never | No ATT prompt required |
| Push token | Never | — |

The SDK requires **no NSPrivacyAccessedAPITypes** entries in `PrivacyInfo.xcprivacy` and triggers no App Tracking Transparency prompt.

---

## 15. SDK Distribution

| Channel | Details |
|---|---|
| Swift Package Manager | `https://github.com/monitoor/ios-sdk-swift` (preferred) |
| CocoaPods | `pod 'MonitoorSDK'` |
| Manual | `.xcframework` download from the dashboard |

**Minimum deployment target:** iOS 15 (required for StoreKit 2 and `async`/`await`).

**Binary size budget:** The SDK should add less than 500KB to the app binary. No third-party dependencies — only Foundation, Network, StoreKit, and SQLite3 (system-provided).
