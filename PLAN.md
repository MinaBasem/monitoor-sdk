# Monitoor SDK — End-to-End Implementation Plan

**Audience:** This document is written for Claude Code. It contains everything needed to implement the Monitoor iOS SDK, its backend ingest service, and the PostgreSQL database schema from scratch. Read it fully before writing any code.

**Reference documents (in the same repo):**
- `SDK.md` — design decisions, data models, gap analysis, wire formats
- `monitoor-website/` — the React dashboard this SDK feeds data into

---

## Part 0 — What You Are Building

Three components, implemented in this order:

```
1. PostgreSQL schema          (the data store)
2. Ingest Service             (thin HTTP API, Go)
3. MonitoorSDK                (iOS Swift package)
```

The iOS SDK streams batched events over HTTPS to the Ingest Service. The Ingest Service authenticates the request via API key, validates the payload, and bulk-inserts into PostgreSQL. The dashboard (already built in React) reads from PostgreSQL via a separate query API that is out of scope for this plan.

**Never** have the iOS SDK connect directly to PostgreSQL. The reasons are documented in `SDK.md §1`.

---

## Part 1 — Repository Structure

Create two new repositories alongside the existing `monitoor-website/`:

```
monitoor-ingest/          ← Go ingest service
  cmd/
    server/
      main.go
  internal/
    auth/
      keys.go             ← API key verification
    handler/
      ingest.go           ← POST /v1/ingest
      crashes.go          ← POST /v1/crashes
      health.go           ← GET /health
    db/
      postgres.go         ← connection pool setup
      queries.go          ← all SQL statements
    model/
      event.go
      crash.go
      session.go
    ratelimit/
      limiter.go          ← per-key sliding window
    middleware/
      auth.go
      ratelimit.go
      decompress.go
  migrations/
    001_initial_schema.sql
    002_indexes.sql
    003_partitions.sql
  config/
    config.go             ← reads env vars
  .env.example
  Dockerfile
  docker-compose.yml      ← postgres + pgbouncer + ingest for local dev

monitoor-ios-sdk/         ← Swift package
  Package.swift
  Sources/
    MonitoorSDK/
      Monitoor.swift              ← public API surface
      MonitoorOptions.swift       ← configuration struct
      Core/
        DeviceIdentity.swift      ← Keychain device_id
        SessionManager.swift      ← session lifecycle
        UserIdentity.swift        ← identify(), reset()
      Capture/
        EventCapture.swift        ← track(), startTimer()
        ScreenCapture.swift       ← UIKit swizzle + SwiftUI modifier
        CrashCapture.swift        ← signal + exception handlers
        RevenueCapture.swift      ← StoreKit 2 + manual
      Buffer/
        LocalBuffer.swift         ← SQLite WAL queue
        BufferSchema.swift        ← CREATE TABLE statements
      Flush/
        FlushEngine.swift         ← timer, triggers, retry loop
        BatchEncoder.swift        ← JSON + gzip
        HTTPClient.swift          ← URLSession wrapper
      Models/
        Event.swift
        Batch.swift
        CrashReport.swift
  Tests/
    MonitoorSDKTests/
      BufferTests.swift
      FlushEngineTests.swift
      AuthTests.swift
      SessionTests.swift
  README.md
```

---

## Part 2 — PostgreSQL Schema

### File: `monitoor-ingest/migrations/001_initial_schema.sql`

Run this against a fresh Postgres database (local or EC2). Use `psql` or any migration tool.

```sql
CREATE EXTENSION IF NOT EXISTS "pgcrypto";  -- for gen_random_uuid()

-- ── Organizations ──────────────────────────────────────────────────
CREATE TABLE organizations (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL,
  email       TEXT NOT NULL UNIQUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Apps ───────────────────────────────────────────────────────────
CREATE TABLE apps (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id        UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  app_store_id  TEXT NOT NULL UNIQUE,  -- Apple numeric ID e.g. "6450454949"
  bundle_id     TEXT,                  -- populated on first ingest
  platform      TEXT NOT NULL DEFAULT 'ios',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── API Keys ───────────────────────────────────────────────────────
-- key_sha256: SHA-256 of the plaintext key, used for fast O(1) lookup
-- key_hash:   bcrypt hash, kept for secondary verification if needed
CREATE TABLE api_keys (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id        UUID NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  key_sha256    TEXT NOT NULL UNIQUE,  -- indexed, used for every auth lookup
  key_hash      TEXT NOT NULL,         -- bcrypt(plaintext, cost=12), for audit
  key_prefix    TEXT NOT NULL,         -- "mn_live_a3f8...9x2k" display only
  environment   TEXT NOT NULL CHECK (environment IN ('production', 'development')),
  label         TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_used_at  TIMESTAMPTZ,
  revoked_at    TIMESTAMPTZ
);

CREATE INDEX idx_api_keys_sha256 ON api_keys (key_sha256) WHERE revoked_at IS NULL;

-- ── Sessions ───────────────────────────────────────────────────────
CREATE TABLE sessions (
  id            UUID PRIMARY KEY,           -- generated by SDK
  app_id        UUID NOT NULL REFERENCES apps(id),
  device_id     TEXT NOT NULL,
  user_id_hash  TEXT,                       -- SHA-256 of developer's user ID
  started_at    TIMESTAMPTZ NOT NULL,
  ended_at      TIMESTAMPTZ,
  duration_s    INT,
  device_model  TEXT,
  os_version    TEXT,
  app_version   TEXT,
  build         TEXT,
  environment   TEXT NOT NULL,
  country       TEXT,                       -- resolved from IP, IP then discarded
  received_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Events (partitioned by month) ─────────────────────────────────
-- IMPORTANT: Add a new partition every month before it starts.
-- Automate this with a cron job on the EC2 instance.
CREATE TABLE events (
  id               UUID NOT NULL DEFAULT gen_random_uuid(),
  app_id           UUID NOT NULL,             -- NOT a FK on partitioned tables in PG<16
  session_id       UUID,
  device_id        TEXT NOT NULL,
  user_id_hash     TEXT,
  name             TEXT NOT NULL,
  properties       JSONB,
  idempotency_key  TEXT,
  app_version      TEXT,
  os_version       TEXT,
  device_model     TEXT,
  bundle_id        TEXT,
  environment      TEXT NOT NULL,
  occurred_at      TIMESTAMPTZ NOT NULL,
  received_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (id, occurred_at)
) PARTITION BY RANGE (occurred_at);

-- ── Crashes ────────────────────────────────────────────────────────
CREATE TABLE crashes (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id           UUID NOT NULL REFERENCES apps(id),
  fingerprint      TEXT NOT NULL,    -- SHA-256 of normalized top-5 frame addresses
  name             TEXT NOT NULL,
  reason           TEXT,
  severity         TEXT NOT NULL CHECK (severity IN ('critical', 'high', 'medium', 'low')),
  status           TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved', 'ignored')),
  app_version      TEXT,
  os_version       TEXT,
  device_model     TEXT,
  first_seen_at    TIMESTAMPTZ NOT NULL,
  last_seen_at     TIMESTAMPTZ NOT NULL,
  occurrence_count INT NOT NULL DEFAULT 1,
  affected_users   INT NOT NULL DEFAULT 1,
  raw_report       JSONB NOT NULL,
  symbolicated     BOOLEAN NOT NULL DEFAULT FALSE,
  idempotency_key  TEXT UNIQUE,
  environment      TEXT NOT NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Revenue Events ─────────────────────────────────────────────────
CREATE TABLE revenue_events (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id          UUID NOT NULL REFERENCES apps(id),
  session_id      UUID,
  device_id       TEXT,
  user_id_hash    TEXT,
  product_id      TEXT NOT NULL,
  amount_usd      NUMERIC(10, 4) NOT NULL,
  currency        TEXT NOT NULL,
  original_amount NUMERIC(10, 4) NOT NULL,
  transaction_id  TEXT NOT NULL,
  type            TEXT NOT NULL CHECK (type IN ('subscription', 'one_time', 'consumable')),
  environment     TEXT NOT NULL,
  app_version     TEXT,
  occurred_at     TIMESTAMPTZ NOT NULL,
  received_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (app_id, transaction_id)
);

-- ── dSYM files (for crash symbolication) ──────────────────────────
CREATE TABLE dsyms (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id       UUID NOT NULL REFERENCES apps(id),
  build_uuid   TEXT NOT NULL UNIQUE,   -- matches LC_UUID in Mach-O binary
  app_version  TEXT NOT NULL,
  build        TEXT NOT NULL,
  file_path    TEXT NOT NULL,          -- path on disk (or S3 key later)
  uploaded_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

### File: `monitoor-ingest/migrations/002_indexes.sql`

```sql
-- Sessions
CREATE INDEX idx_sessions_app_device  ON sessions (app_id, device_id, started_at DESC);

-- Events (indexes are created per-partition automatically in Postgres 11+)
CREATE INDEX idx_events_app_name_time ON events (app_id, name, occurred_at DESC);
CREATE INDEX idx_events_app_device    ON events (app_id, device_id, occurred_at DESC);
CREATE INDEX idx_events_properties    ON events USING GIN (properties);
CREATE UNIQUE INDEX idx_events_idem   ON events (idempotency_key)
  WHERE idempotency_key IS NOT NULL;

-- Crashes
CREATE INDEX idx_crashes_app_fingerprint ON crashes (app_id, fingerprint);
CREATE INDEX idx_crashes_open            ON crashes (app_id, severity, last_seen_at DESC)
  WHERE status = 'open';

-- Revenue
CREATE INDEX idx_revenue_app_occurred ON revenue_events (app_id, occurred_at DESC);
CREATE INDEX idx_revenue_app_product  ON revenue_events (app_id, product_id);
```

### File: `monitoor-ingest/migrations/003_partitions.sql`

```sql
-- Create the first partitions manually. Automate adding future ones.
CREATE TABLE events_2026_05 PARTITION OF events
  FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');

CREATE TABLE events_2026_06 PARTITION OF events
  FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');

CREATE TABLE events_2026_07 PARTITION OF events
  FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');

-- Monthly cron job on EC2 to create future partitions:
-- 0 0 20 * * psql $DB_URL -c "CREATE TABLE events_$(date -d '+1 month' +'%Y_%m') ..."
```

---

## Part 3 — Ingest Service (Go)

### Why Go

- Single static binary, trivial to deploy on EC2.
- Excellent `net/http` stdlib — no framework needed.
- `pgx` is the best Postgres driver available.
- Easy to compile locally and cross-compile for Linux (EC2).

### Environment variables

```bash
# .env.example
DATABASE_URL=postgres://monitoor:secret@localhost:5432/monitoor?sslmode=disable
PORT=8080
RATE_LIMIT_EVENTS_PER_HOUR=1000       # per device_id
RATE_LIMIT_REQUESTS_PER_MINUTE=100    # per api key
MAX_BATCH_SIZE=200                     # reject batches larger than this
MAX_EVENT_FUTURE_SECONDS=300           # 5 min clock skew tolerance
MAX_EVENT_AGE_HOURS=168                # 7 days — drop older events
```

For local development: copy `.env.example` to `.env` and run `source .env` before starting the server.

For EC2: set these as environment variables in the systemd service file or via AWS Parameter Store.

### Implementation steps

#### Step 3.1 — `config/config.go`

Read all env vars at startup. Fail fast with a clear error if any required var is missing. Do not use a config file — env vars are simpler to manage across local and EC2.

```go
type Config struct {
    DatabaseURL                string
    Port                       string
    RateLimitEventsPerHour     int
    RateLimitRequestsPerMinute int
    MaxBatchSize               int
    MaxEventFutureSeconds      int
    MaxEventAgeHours           int
}

func Load() (*Config, error) { ... }
```

#### Step 3.2 — `internal/db/postgres.go`

Use `pgx/v5/pgxpool` (connection pool built into pgx — no PgBouncer needed for local dev; add PgBouncer on EC2 when traffic warrants it).

```go
func Connect(databaseURL string) (*pgxpool.Pool, error) {
    config, err := pgxpool.ParseConfig(databaseURL)
    config.MaxConns = 20
    config.MinConns = 2
    config.MaxConnLifetime = 30 * time.Minute
    return pgxpool.NewWithConfig(context.Background(), config)
}
```

#### Step 3.3 — `internal/auth/keys.go`

API key authentication is the most critical path. Every ingest request goes through here.

```
Incoming key: "mn_live_a3f8b2c4d5e6f7g8h9i0j1k2l3m4n9x2k"

1. sha256_hex = hex(SHA-256(incoming_key))
2. SELECT id, app_id, environment, revoked_at
   FROM api_keys
   WHERE key_sha256 = sha256_hex
     AND revoked_at IS NULL
   LIMIT 1
3. If no row → return 401 Unauthorized
4. UPDATE api_keys SET last_used_at = NOW() WHERE id = $row.id
5. Return app_id, environment
```

**Important:** Validate that the key prefix matches the environment in the request body. A `mn_dev_` key used to send `environment: "production"` events should be rejected.

Key generation (dashboard side, not ingest service):

```go
func GenerateKey(env string) (plaintext, sha256hex, bcryptHash, prefix string, err error) {
    raw := make([]byte, 24)
    rand.Read(raw)
    suffix := hex.EncodeToString(raw)  // 48 chars

    var envPrefix string
    if env == "production" {
        envPrefix = "mn_live"
    } else {
        envPrefix = "mn_dev"
    }

    plaintext = envPrefix + "_" + suffix
    sha256bytes := sha256.Sum256([]byte(plaintext))
    sha256hex = hex.EncodeToString(sha256bytes[:])
    bcryptBytes, _ := bcrypt.GenerateFromPassword([]byte(plaintext), 12)
    bcryptHash = string(bcryptBytes)
    prefix = plaintext[:15] + "..." + plaintext[len(plaintext)-4:]
    return
}
```

#### Step 3.4 — `internal/ratelimit/limiter.go`

Implement a simple in-memory sliding window rate limiter. Use `sync.Map` keyed by API key ID.

Two limits enforced independently:
1. **Requests per minute** (per API key) — prevents flood of HTTP calls.
2. **Events per hour** (per device_id within a key's app) — prevents event flooding.

Return `429` with `Retry-After: <seconds>` header when exceeded. The SDK handles `429` by backing off and not marking the batch as failed.

For production at scale, replace the in-memory store with a Redis `INCR` + `EXPIRE` pattern. For now, in-memory is sufficient.

#### Step 3.5 — `internal/handler/ingest.go`

This is the main endpoint. Implement it in this exact order:

```
1.  Parse Authorization header → extract bearer token
2.  Authenticate → get app_id, environment (§3.3)
3.  Check rate limit (requests/min) → 429 if exceeded
4.  Decompress body if Content-Encoding: gzip
5.  Decode JSON body into IngestRequest struct
6.  Validate: batch length <= MAX_BATCH_SIZE → 400 if exceeded
7.  Reject entire request if batch is empty
8.  For each event in the batch:
    a. Validate required fields: name, occurred_at, device_id, session_id
    b. Validate occurred_at not in the future (> now + MAX_EVENT_FUTURE_SECONDS)
    c. Validate occurred_at not too old (< now - MAX_EVENT_AGE_HOURS)
    d. Attach app_id from auth result
    e. Attach environment from auth result
    f. Populate received_at = NOW()
    g. Collect errors per-index for invalid events
9.  Check rate limit (events/hour per device_id) → 429 if exceeded
10. Bulk INSERT valid events using pgx COPY protocol (fastest bulk insert)
    → ON CONFLICT (idempotency_key) DO NOTHING
11. Upsert session rows (INSERT ... ON CONFLICT (id) DO UPDATE)
12. Update apps.bundle_id if not yet set (from context.bundle_id in payload)
13. Return: { "accepted": N, "rejected": M, "errors": [...] }
```

**Use `pgx` COPY protocol for bulk insert, not individual INSERTs.** This is 10–50x faster for batches:

```go
_, err = pool.CopyFrom(
    ctx,
    pgx.Identifier{"events"},
    []string{"id", "app_id", "session_id", "device_id", "name", "properties",
             "idempotency_key", "app_version", "os_version", "device_model",
             "bundle_id", "environment", "occurred_at", "received_at"},
    pgx.CopyFromRows(rows),
)
```

COPY does not support `ON CONFLICT`. For idempotency with COPY, insert into a temporary table first, then `INSERT INTO events SELECT ... FROM temp ON CONFLICT DO NOTHING`. See `pgx` docs for the pattern.

#### Step 3.6 — `internal/handler/crashes.go`

```
1.  Authenticate (same as ingest)
2.  Decode crash report JSON
3.  Compute fingerprint: SHA-256 of the top 5 crashed-thread frame addresses, hex-encoded
4.  Classify severity from exception_type/signal (see SDK.md §7)
5.  Upsert into crashes:
    INSERT INTO crashes (fingerprint, app_id, ...)
    ON CONFLICT (app_id, fingerprint) DO UPDATE SET
      occurrence_count = crashes.occurrence_count + 1,
      last_seen_at = EXCLUDED.last_seen_at,
      affected_users = (SELECT COUNT(DISTINCT device_id) FROM crash_occurrences WHERE fingerprint = ...)
6.  Return { "crash_id": "uuid", "symbolicated": false }
```

#### Step 3.7 — `cmd/server/main.go`

Wire everything together:

```go
func main() {
    cfg := config.Load()
    pool := db.Connect(cfg.DatabaseURL)
    limiter := ratelimit.New(cfg)

    mux := http.NewServeMux()
    mux.Handle("POST /v1/ingest",  middleware.Chain(handler.Ingest(pool, limiter, cfg), middleware.Auth(pool), middleware.Decompress()))
    mux.Handle("POST /v1/crashes", middleware.Chain(handler.Crashes(pool, cfg), middleware.Auth(pool)))
    mux.Handle("GET /health",      handler.Health(pool))

    log.Printf("Ingest service listening on :%s", cfg.Port)
    http.ListenAndServe(":"+cfg.Port, mux)
}
```

#### Step 3.8 — `docker-compose.yml` (local development)

```yaml
services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_DB: monitoor
      POSTGRES_USER: monitoor
      POSTGRES_PASSWORD: secret
    ports:
      - "5432:5432"
    volumes:
      - pg_data:/var/lib/postgresql/data
      - ./migrations:/docker-entrypoint-initdb.d   # runs migrations on first start

  ingest:
    build: .
    environment:
      DATABASE_URL: postgres://monitoor:secret@postgres:5432/monitoor?sslmode=disable
      PORT: 8080
    ports:
      - "8080:8080"
    depends_on:
      - postgres

volumes:
  pg_data:
```

Run locally with `docker compose up`. The iOS simulator can reach it at `http://localhost:8080`.

#### Step 3.9 — `Dockerfile`

```dockerfile
FROM golang:1.23-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o ingest ./cmd/server

FROM alpine:3.20
COPY --from=builder /app/ingest /ingest
EXPOSE 8080
CMD ["/ingest"]
```

---

## Part 4 — iOS SDK (Swift Package)

### Step 4.1 — `Package.swift`

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MonitoorSDK",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "MonitoorSDK", targets: ["MonitoorSDK"]),
    ],
    targets: [
        .target(
            name: "MonitoorSDK",
            dependencies: [],
            path: "Sources/MonitoorSDK",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "MonitoorSDKTests",
            dependencies: ["MonitoorSDK"],
            path: "Tests/MonitoorSDKTests"
        ),
    ]
)
```

No third-party dependencies. Use only:
- `Foundation` (URLSession, JSONEncoder)
- `Network` (NWPathMonitor)
- `StoreKit` (transaction tracking)
- `SQLite3` (system-provided C library, linked via `-lsqlite3`)
- `Security` (Keychain)
- `CryptoKit` (SHA-256 for user ID hashing)

### Step 4.2 — `MonitoorOptions.swift`

```swift
public struct MonitoorOptions {
    public var ingestURL: URL
    public var environment: Environment
    public var captureEvents: Bool
    public var captureScreenViews: Bool
    public var captureRevenue: Bool
    public var captureCrashes: Bool
    public var captureClickHeatmaps: Bool    // default: false
    public var captureSessionRecordings: Bool // default: false
    public var flushInterval: TimeInterval   // default: 20s
    public var flushBatchSize: Int           // default: 50
    public var maxBufferAge: TimeInterval    // default: 72h

    public enum Environment: String {
        case production  = "production"
        case development = "development"
    }

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
        maxBufferAge: TimeInterval = 72 * 3600
    ) { ... }
}
```

### Step 4.3 — `Monitoor.swift` (public API)

This is the only file SDK users import from. All other files are internal.

```swift
public final class Monitoor {
    // MARK: - Public API

    public static func configure(apiKey: String, options: MonitoorOptions = .init()) {
        shared.setup(apiKey: apiKey, options: options)
    }

    public static func track(_ name: String, properties: [String: Any] = [:]) {
        shared.capture(name: name, properties: properties)
    }

    public static func screen(_ name: String, properties: [String: Any] = [:]) {
        shared.capture(name: "$screen_view", properties: ["$screen_name": name].merging(properties) { $1 })
    }

    public static func identify(userId: String) {
        shared.identity.setUserId(userId)
    }

    public static func setUserProperties(_ properties: [String: Any]) {
        shared.identity.setProperties(properties)
    }

    public static func reset() {
        shared.identity.reset()
        shared.session.reset()
    }

    public static func startTimer(_ name: String) {
        shared.timers[name] = Date()
    }

    public static func trackRevenue(
        productId: String,
        amount: Double,
        currency: String,
        type: RevenueType,
        transactionId: String,
        userId: String? = nil
    ) {
        shared.revenue.track(...)
    }

    public static func flush(completion: (() -> Void)? = nil) {
        shared.flushEngine.flush(completion: completion)
    }

    // MARK: - Internal singleton
    static let shared = MonitoorCore()
    private init() {}
}
```

### Step 4.4 — `Core/DeviceIdentity.swift`

```swift
// Stores a UUID in the Keychain.
// Survives app updates. Regenerated on reinstall if iCloud Keychain is disabled.
// kSecAttrService: "io.monitoor.sdk"
// kSecAttrAccount: "device_id"
// kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock

final class DeviceIdentity {
    let deviceId: String

    init() {
        if let existing = Keychain.read(key: "device_id") {
            deviceId = existing
        } else {
            let new = UUID().uuidString
            Keychain.write(key: "device_id", value: new)
            deviceId = new
        }
    }
}
```

### Step 4.5 — `Core/SessionManager.swift`

```swift
// Session lifecycle rules:
// - New session on app foreground if last event > 30 min ago
// - session_id is a UUID, generated at session start
// - Session end is flushed on background / terminate
// - On launch, if previous session has no ended_at, synthesize session_end event

final class SessionManager {
    private(set) var sessionId: UUID = UUID()
    private(set) var sessionStart: Date = Date()
    private var lastEventAt: Date = Date()
    private let sessionTimeout: TimeInterval = 30 * 60

    func recordEvent() {
        lastEventAt = Date()
    }

    func handleForeground() -> Bool {
        // Returns true if a new session was started
        if Date().timeIntervalSince(lastEventAt) > sessionTimeout {
            startNewSession()
            return true
        }
        return false
    }

    func handleBackground() {
        // Enqueue $session_pause event
    }

    private func startNewSession() {
        sessionId = UUID()
        sessionStart = Date()
    }

    func reset() {
        startNewSession()
    }
}
```

### Step 4.6 — `Core/UserIdentity.swift`

```swift
import CryptoKit

final class UserIdentity {
    private(set) var userIdHash: String?
    private(set) var properties: [String: Any] = [:]

    func setUserId(_ userId: String) {
        // SHA-256 hash before storing
        let data = Data(userId.utf8)
        let hash = SHA256.hash(data: data)
        userIdHash = hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    func setProperties(_ props: [String: Any]) {
        properties.merge(props) { _, new in new }
    }

    func reset() {
        userIdHash = nil
        properties = [:]
    }
}
```

### Step 4.7 — `Buffer/LocalBuffer.swift`

The buffer uses SQLite3 via the system C library. Import with `import SQLite3`.

**SQLite setup:**
- File path: `FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!.appendingPathComponent("monitoor_buffer.db")`
- WAL mode: `PRAGMA journal_mode=WAL`
- Excluded from iCloud backup: `var resourceValues = URLResourceValues(); resourceValues.isExcludedFromBackup = true`

**Schema:**
```sql
CREATE TABLE IF NOT EXISTS buffer (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  payload     TEXT    NOT NULL,
  type        TEXT    NOT NULL DEFAULT 'event',  -- 'event' | 'crash' | 'session'
  created_at  INTEGER NOT NULL,                  -- Unix ms
  attempts    INTEGER NOT NULL DEFAULT 0,
  status      TEXT    NOT NULL DEFAULT 'pending' -- 'pending' | 'failed'
);
```

**Key methods:**
```swift
func enqueue(payload: Data, type: String) throws
func dequeue(limit: Int) throws -> [(id: Int64, payload: Data, type: String)]
func markSent(ids: [Int64]) throws
func markFailed(ids: [Int64]) throws
func pruneExpired(maxAge: TimeInterval) throws  // DELETE WHERE created_at < threshold
func pendingCount() throws -> Int
```

All SQLite calls must be made on a dedicated serial `DispatchQueue` (not the main queue). Never call SQLite from multiple threads without serialization — WAL mode handles concurrent reads but writes must be serialized.

### Step 4.8 — `Flush/FlushEngine.swift`

The flush engine is the heart of the SDK. Implement it carefully.

```swift
final class FlushEngine {
    private let buffer: LocalBuffer
    private let httpClient: HTTPClient
    private let options: MonitoorOptions
    private var timer: Timer?
    private var isFlushing = false
    private let queue = DispatchQueue(label: "io.monitoor.flush")

    func start() {
        setupTimer()
        setupNetworkMonitor()
        setupAppLifecycleObservers()
    }

    func flush(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self, !self.isFlushing else { return }
            self.isFlushing = true
            self.drainBuffer(completion: completion)
        }
    }

    // Drain loop — send batches until buffer is empty
    private func drainBuffer(completion: (() -> Void)?) {
        do {
            let rows = try buffer.dequeue(limit: options.flushBatchSize)
            guard !rows.isEmpty else {
                isFlushing = false
                completion?()
                return
            }

            let batch = Batch(rows: rows)
            let result = httpClient.send(batch: batch, apiKey: apiKey, ingestURL: options.ingestURL)

            switch result {
            case .success(let response):
                // Delete successfully accepted events
                let successIds = batch.idsExcluding(rejectedIndexes: response.errors.map { $0.index })
                try buffer.markSent(ids: successIds)

                // Permanently drop server-rejected events (4xx) — do not retry
                let rejectedIds = response.errors.map { batch.ids[$0.index] }
                try buffer.markFailed(ids: rejectedIds)

                // Continue draining
                drainBuffer(completion: completion)

            case .rateLimited(let retryAfter):
                // Back off — do not mark as failed, leave as pending
                isFlushing = false
                scheduleRetry(after: retryAfter)
                completion?()

            case .serverError(let attempt):
                // Exponential backoff — 1s, 2s, 4s, 8s ... max 300s
                let delay = min(pow(2.0, Double(attempt)), 300.0)
                isFlushing = false
                scheduleRetry(after: delay)
                completion?()

            case .clientError:
                // Malformed batch — mark all as failed, move on
                try buffer.markFailed(ids: batch.ids)
                drainBuffer(completion: completion)
            }
        } catch {
            isFlushing = false
            completion?()
        }
    }
}
```

**Flush triggers — register all of these in `start()`:**

```swift
// Timer
timer = Timer.scheduledTimer(withTimeInterval: options.flushInterval, repeats: true) { _ in
    self.flush()
}

// Background
NotificationCenter.default.addObserver(forName: UIScene.willDeactivateNotification, ...) { _ in
    self.flush()
}

// Terminate — must complete within system's time limit (~5s)
NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, ...) { _ in
    let sema = DispatchSemaphore(value: 0)
    self.flush { sema.signal() }
    sema.wait(timeout: .now() + 3)
}

// Network restored
let monitor = NWPathMonitor()
monitor.pathUpdateHandler = { path in
    if path.status == .satisfied { self.flush() }
}
monitor.start(queue: DispatchQueue(label: "io.monitoor.network"))
```

### Step 4.9 — `Flush/BatchEncoder.swift`

```swift
struct BatchEncoder {
    func encode(events: [BufferedEvent], context: Context) throws -> Data {
        let batch = IngestBatch(
            sdkVersion: MonitoorSDK.version,
            batch: events.map { IngestEvent(buffered: $0, context: context) }
        )
        let json = try JSONEncoder().encode(batch)
        return json.count > 1024 ? try compress(json) : json
    }

    private func compress(_ data: Data) throws -> Data {
        // Use Foundation's compression (iOS 13+)
        // NSData(data: data).compressed(using: .zlib)
        // Set Content-Encoding: gzip header on the request
    }
}
```

### Step 4.10 — `Capture/CrashCapture.swift`

Crash handling must be async-signal-safe. This means:

- No `malloc`, no Objective-C, no Swift ARC in the signal handler body.
- Use only `write()`, `open()`, `close()` syscalls.
- Pre-allocate a static buffer at init time for writing the crash report.

```swift
final class CrashCapture {
    private static var crashFilePath: UnsafeMutablePointer<CChar>? = nil
    private static var preallocatedBuffer: UnsafeMutablePointer<CChar>? = nil
    private static let bufferSize = 65536  // 64KB

    static func install(crashDirectory: URL) {
        // Pre-allocate crash report buffer
        preallocatedBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
        crashFilePath = strdup((crashDirectory.path + "/crash_\(Date().timeIntervalSince1970).json").cString(using: .utf8)!)

        NSSetUncaughtExceptionHandler { exception in
            CrashCapture.handleException(exception)
        }

        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { signal in
                CrashCapture.handleSignal(signal)
            }
            sigaction(sig, &action, nil)
        }
    }

    // This function MUST be async-signal-safe
    private static func handleSignal(_ signal: Int32) {
        writeCrashReport(signal: signal, exception: nil)
        raise(signal)  // re-raise to get default behavior (generates crash log)
    }

    private static func handleException(_ exception: NSException) {
        writeCrashReport(signal: 0, exception: exception)
    }

    private static func writeCrashReport(signal: Int32, exception: NSException?) {
        // Use backtrace() + backtrace_symbols_fd() (async-signal-safe)
        // Write JSON manually using write() syscall into preallocatedBuffer
        // No malloc, no print, no ObjC
    }

    // Call on NEXT app launch
    static func uploadPendingCrashes(to uploader: CrashUploader) {
        let dir = crashDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, ...) else { return }
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file) {
                uploader.upload(data) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }
}
```

### Step 4.11 — `Capture/ScreenCapture.swift`

```swift
// UIKit: swizzle viewDidAppear
extension UIViewController {
    static func monitoor_swizzle() {
        let original = #selector(viewDidAppear(_:))
        let swizzled = #selector(monitoor_viewDidAppear(_:))
        guard
            let originalMethod = class_getInstanceMethod(UIViewController.self, original),
            let swizzledMethod = class_getInstanceMethod(UIViewController.self, swizzled)
        else { return }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    @objc func monitoor_viewDidAppear(_ animated: Bool) {
        monitoor_viewDidAppear(animated)  // calls original (due to swizzle)
        let name = String(describing: type(of: self))
            .replacingOccurrences(of: "ViewController", with: "")
            .replacingOccurrences(of: "Controller", with: "")
            .replacingOccurrences(of: "VC", with: "")
        Monitoor.screen(name)
    }
}

// SwiftUI: view modifier
public struct MonitoorScreenModifier: ViewModifier {
    let name: String
    let properties: [String: Any]

    public func body(content: Content) -> some View {
        content.onAppear {
            Monitoor.screen(name, properties: properties)
        }
    }
}

public extension View {
    func monitoorScreen(_ name: String, properties: [String: Any] = [:]) -> some View {
        modifier(MonitoorScreenModifier(name: name, properties: properties))
    }
}
```

### Step 4.12 — `Capture/RevenueCapture.swift`

```swift
final class RevenueCapture {
    func startObserving() {
        Task {
            for await result in Transaction.updates {
                if case .verified(let tx) = result {
                    trackTransaction(tx)
                }
            }
        }
    }

    private func trackTransaction(_ tx: Transaction) {
        // Extract: productID, price, currency, transactionDate, transactionIdentifier
        // Map product type: .autoRenewable → "subscription", .nonConsumable → "one_time", etc.
        let props: [String: Any] = [
            "product_id": tx.productID,
            "amount": tx.price ?? 0,
            "currency": tx.currency?.identifier ?? "USD",
            "transaction_id": String(tx.id),
            "type": mapProductType(tx.productType)
        ]
        // Enqueue as a revenue-type payload to the buffer
    }
}
```

---

## Part 5 — Wire Format Reference

This is the exact JSON the SDK sends. The ingest service must parse this schema exactly.

### Ingest payload

```json
{
  "sdk_version": "1.0.0",
  "batch": [
    {
      "type": "event",
      "name": "portfolio_created",
      "session_id": "550e8400-e29b-41d4-a716-446655440000",
      "device_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
      "idempotency_key": "a1b2c3d4-550e8400-1717070581234",
      "occurred_at": "2026-05-30T14:23:01.234Z",
      "properties": {
        "asset_count": 5,
        "template": "growth"
      },
      "context": {
        "app_version": "2.1.0",
        "build": "214",
        "os": "iOS 17.4",
        "device": "iPhone 15 Pro",
        "locale": "en_US",
        "timezone": "America/Los_Angeles",
        "bundle_id": "com.example.folio"
      }
    }
  ]
}
```

### Ingest response

```json
{
  "accepted": 49,
  "rejected": 1,
  "errors": [
    { "index": 12, "reason": "occurred_at is in the future" }
  ]
}
```

### Crash payload

```json
{
  "sdk_version": "1.0.0",
  "type": "crash",
  "idempotency_key": "a1b2c3d4-crash-1717070581234",
  "exception_type": "EXC_BAD_ACCESS",
  "exception_name": "SIGSEGV",
  "signal": 11,
  "reason": "KERN_INVALID_ADDRESS at 0x0000000000000000",
  "app_version": "2.1.0",
  "build": "214",
  "os_version": "iOS 17.4",
  "device": "iPhone 15 Pro",
  "session_id": "550e8400-e29b-41d4-a716-446655440000",
  "device_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "occurred_at": "2026-05-30T14:23:01.234Z",
  "threads": [
    {
      "index": 0,
      "crashed": true,
      "frames": [
        { "index": 0, "image": "Folio", "address": "0x000000010045a3bc", "offset": 1234 },
        { "index": 1, "image": "Folio", "address": "0x000000010045a200", "offset": 512 }
      ]
    }
  ]
}
```

---

## Part 6 — Testing

### Ingest service tests

Write integration tests (not unit tests with mocks) using a real Postgres instance spun up via `testcontainers-go` or a fixed local Postgres.

**Tests to write:**

```
TestIngest_ValidBatch          → 200, all events inserted
TestIngest_ExpiredKey          → 401
TestIngest_RevokedKey          → 401
TestIngest_MissingFields       → 200 with rejected events in response
TestIngest_FutureTimestamp     → event rejected
TestIngest_IdempotentRetry     → second POST of same batch inserts 0 new rows
TestIngest_RateLimit           → 429 after threshold
TestIngest_OversizedBatch      → 400
TestIngest_GzipPayload         → 200, decompressed and inserted correctly
TestCrashes_NewCrash           → 201, new row in crashes
TestCrashes_DuplicateCrash     → 200, occurrence_count incremented
TestHealth                     → 200
```

### iOS SDK tests

Use `XCTest`. For SQLite buffer tests, use a temporary in-memory database (`":memory:"`).

```
BufferTests:
  testEnqueueAndDequeue
  testMarkSent_deletesRows
  testMarkFailed_setsStatus
  testPruneExpired_deletesOldRows
  testConcurrentEnqueue_noDataRace

FlushEngineTests:
  testFlush_sendsAllPendingEvents
  testFlush_retriesOn500
  testFlush_dropsOn400
  testFlush_backsOffOn429
  testFlush_deduplicatesIdempotentRetry

SessionTests:
  testNewSessionAfterTimeout
  testSameSessionWithinTimeout
  testResetClearsSession

AuthTests:
  testKeyPrefixValidation_productionKeyWithDevEnvironment_fails
  testKeyPrefixValidation_devKeyWithProductionEnvironment_fails
```

---

## Part 7 — EC2 Deployment

### Instance recommendation

**t3.small** (2 vCPU, 2GB RAM) is sufficient to start. Postgres and the ingest service run on the same instance.

### Setup checklist

```bash
# 1. Install Postgres 16
sudo apt install postgresql-16

# 2. Create database and user
sudo -u postgres psql -c "CREATE USER monitoor WITH PASSWORD 'your_password';"
sudo -u postgres psql -c "CREATE DATABASE monitoor OWNER monitoor;"

# 3. Run migrations
psql postgres://monitoor:password@localhost/monitoor -f migrations/001_initial_schema.sql
psql postgres://monitoor:password@localhost/monitoor -f migrations/002_indexes.sql
psql postgres://monitoor:password@localhost/monitoor -f migrations/003_partitions.sql

# 4. Build ingest service (cross-compile from Mac)
GOOS=linux GOARCH=amd64 go build -o ingest ./cmd/server

# 5. Copy binary to EC2
scp ingest ec2-user@<ec2-ip>:/usr/local/bin/monitoor-ingest

# 6. Create systemd service
# /etc/systemd/system/monitoor-ingest.service
[Unit]
Description=Monitoor Ingest Service
After=network.target postgresql.service

[Service]
ExecStart=/usr/local/bin/monitoor-ingest
Environment=DATABASE_URL=postgres://monitoor:password@localhost/monitoor?sslmode=disable
Environment=PORT=8080
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target

sudo systemctl enable monitoor-ingest
sudo systemctl start monitoor-ingest

# 7. EC2 Security Group: allow port 443 inbound (HTTPS via nginx/caddy)
#    Never expose port 8080 or 5432 to the public internet

# 8. TLS: use Caddy as a reverse proxy (auto-provisions Let's Encrypt cert)
# /etc/caddy/Caddyfile
ingest.monitoor.io {
  reverse_proxy localhost:8080
}

# 9. Monthly partition cron job
# /etc/cron.d/monitoor-partitions
0 0 20 * * postgres psql $DB_URL -c "
  DO \$\$ DECLARE
    next_month DATE := DATE_TRUNC('month', NOW() + INTERVAL '1 month');
    table_name TEXT := 'events_' || TO_CHAR(next_month, 'YYYY_MM');
  BEGIN
    EXECUTE FORMAT('CREATE TABLE IF NOT EXISTS %I PARTITION OF events FOR VALUES FROM (%L) TO (%L)',
      table_name, next_month, next_month + INTERVAL '1 month');
  END \$\$;"
```

---

## Part 8 — Implementation Order

Follow this order exactly. Each step produces something testable before moving to the next.

```
Phase 1 — Database (1 day)
  [ ] Run migrations locally via docker-compose
  [ ] Verify all tables, indexes, and partitions exist
  [ ] Insert a test row into events, verify it lands in correct partition
  [ ] Test DELETE by device_id

Phase 2 — Ingest Service (3–4 days)
  [ ] config.go — env var loading with validation
  [ ] db/postgres.go — pool setup, ping on startup
  [ ] GET /health — returns 200, verifies DB connection
  [ ] auth/keys.go — key generation + SHA-256 lookup
  [ ] POST /v1/ingest — without rate limiting first
  [ ] Add idempotency (ON CONFLICT DO NOTHING)
  [ ] Add input validation (missing fields, clock skew)
  [ ] Add rate limiting
  [ ] Add gzip decompression middleware
  [ ] POST /v1/crashes — with fingerprint + upsert
  [ ] Write integration tests for all above
  [ ] docker-compose working end-to-end

Phase 3 — iOS SDK, foundation (3–4 days)
  [ ] Package.swift — builds cleanly
  [ ] MonitoorOptions.swift
  [ ] DeviceIdentity.swift — Keychain read/write
  [ ] LocalBuffer.swift — SQLite with WAL mode
  [ ] BufferTests.swift — all passing
  [ ] HTTPClient.swift — URLSession wrapper
  [ ] BatchEncoder.swift — JSON + gzip
  [ ] FlushEngine.swift — drain loop
  [ ] FlushEngineTests.swift — all passing
  [ ] Monitoor.swift — configure() wires everything
  [ ] Verify: track() → buffer → flush → ingest → Postgres

Phase 4 — iOS SDK, capture (2–3 days)
  [ ] SessionManager.swift + tests
  [ ] UserIdentity.swift (SHA-256 hashing) + tests
  [ ] EventCapture.swift — track(), startTimer()
  [ ] ScreenCapture.swift — UIKit swizzle + SwiftUI modifier
  [ ] CrashCapture.swift — signal handlers + next-launch upload
  [ ] RevenueCapture.swift — StoreKit 2 + manual

Phase 5 — EC2 deployment (1 day)
  [ ] Cross-compile ingest binary for Linux
  [ ] Run migrations on EC2 Postgres
  [ ] Systemd service running and stable
  [ ] Caddy TLS proxy in front of port 8080
  [ ] Monthly partition cron job installed
  [ ] Point iOS app at production ingestURL, verify events appear in Postgres

Phase 6 — Hardening (1–2 days)
  [ ] Verify rate limiting blocks abuse
  [ ] Verify idempotency with repeated batch
  [ ] Verify 401 on revoked key
  [ ] Verify expired events rejected
  [ ] Verify crash upload on next launch
  [ ] Verify session_end synthesized correctly
  [ ] Load test: simulate 1000 concurrent devices flushing (use k6 or wrk)
```

---

## Part 9 — Key Decisions Reference

These are the non-obvious decisions made in the design. Do not reverse them without understanding the rationale.

| Decision | Rationale |
|---|---|
| SDK → HTTP → Postgres (not direct) | DB credentials cannot be in the app binary; connection pooling and rate limiting require a server layer |
| SHA-256 for key lookup (not bcrypt) | bcrypt is intentionally slow; using SHA-256 for the DB lookup and bcrypt only for storage is the correct pattern for bearer tokens |
| SQLite WAL buffer on device | Survives app kills mid-flush; crash-safe; no event loss |
| Drain loop (not single flush) | Ensures large offline backlogs are fully drained, not just the first batch |
| Idempotency key on every event | Retry-safe: `ON CONFLICT DO NOTHING` means double-sends are harmless |
| Monthly table partitioning | Old data can be dropped instantly with `DROP TABLE`; query planner prunes irrelevant months |
| No direct PII collection | App Store privacy requirements; SHA-256 user ID means even Monitoor cannot reverse it |
| Session synthesized on next launch | `applicationWillTerminate` is not guaranteed; sessions must be closeable after the fact |
| `mn_live_` / `mn_dev_` key prefixes | Allows immediate environment detection without a DB lookup; prevents prod keys accidentally used in dev |
