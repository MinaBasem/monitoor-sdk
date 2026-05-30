# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repository Is

This is a **planning and specification repository** for the Monitoor iOS analytics SDK. It currently contains design documents only — no code has been written yet. The two key documents are:

- [SDK.md](SDK.md) — Architecture decisions, data models, wire formats, gap analysis, and privacy design. Read this first.
- [PLAN.md](PLAN.md) — Step-by-step implementation instructions for all three components. Includes exact code skeletons, SQL migrations, Dockerfile, and a phased implementation order.

## What You Are Building

Three components implemented in order:

```
1. PostgreSQL schema          (migrations SQL files)
2. Ingest Service             (Go — monitoor-ingest/)
3. MonitoorSDK                (Swift Package — monitoor-ios-sdk/)
```

The iOS SDK streams batched events over HTTPS to the Ingest Service, which authenticates via API key and bulk-inserts into PostgreSQL. **The SDK must never connect directly to PostgreSQL** — see SDK.md §1 for why this is a hard requirement.

## Repository Structure (to be created)

```
monitoor-ingest/          ← Go ingest service
  cmd/server/main.go
  internal/auth/keys.go   ← API key verification (SHA-256 lookup, not bcrypt)
  internal/handler/       ← ingest.go, crashes.go, health.go
  internal/db/            ← pgxpool setup, all SQL
  internal/ratelimit/     ← per-key sliding window
  migrations/             ← 001_initial_schema.sql, 002_indexes.sql, 003_partitions.sql
  docker-compose.yml      ← postgres + ingest for local dev

monitoor-ios-sdk/         ← Swift Package (iOS 15+)
  Sources/MonitoorSDK/
    Monitoor.swift              ← entire public API surface
    Core/                       ← DeviceIdentity, SessionManager, UserIdentity
    Capture/                    ← EventCapture, ScreenCapture, CrashCapture, RevenueCapture
    Buffer/LocalBuffer.swift    ← SQLite WAL queue (serial DispatchQueue)
    Flush/FlushEngine.swift     ← drain loop + all flush triggers
```

## Local Development

### Ingest service

```bash
# Requires Docker
cd monitoor-ingest
docker compose up          # starts postgres:16 + ingest on :8080
```

Migrations in `migrations/` run automatically on first Postgres start via `docker-entrypoint-initdb.d`.

```bash
# Build and run locally without Docker
source .env
go build ./cmd/server && ./server

# Cross-compile for EC2
GOOS=linux GOARCH=amd64 go build -o ingest ./cmd/server
```

### iOS SDK

```bash
cd monitoor-ios-sdk
swift build
swift test                           # run all tests
swift test --filter BufferTests      # run a single test class
```

For manual end-to-end testing, point `ingestURL` at `http://localhost:8080` in a Simulator build.

## Critical Architecture Decisions

These decisions are intentional — do not reverse them without reading the rationale in SDK.md §13 / PLAN.md Part 9.

| Decision | Why |
|---|---|
| SHA-256 for API key DB lookup (not bcrypt scan) | bcrypt is ~100ms; use `SHA-256(key)` indexed for O(1) lookup, store bcrypt only for audit |
| SQLite WAL buffer in the SDK | Survives app kills mid-flush; no event loss even on crash |
| Drain loop in FlushEngine (not single-batch flush) | Large offline backlogs must fully drain, not just the first 50 events |
| `idempotency_key` on every event + `ON CONFLICT DO NOTHING` | Retry-safe: duplicate sends are harmless |
| `events` table partitioned by month from day one | Old data dropped instantly via `DROP TABLE`; query planner prunes irrelevant months. Adding partitioning later requires a full table rewrite. |
| User ID SHA-256 hashed client-side before transmission | Monitoor never sees plaintext user IDs; satisfies App Store privacy requirements |
| Session synthesized on next launch | `applicationWillTerminate` is not guaranteed on iOS (OOM kills, force-quit) |
| `mn_live_` / `mn_dev_` key prefixes | Immediate environment detection without a DB lookup; mismatch is an error at `configure()` time |

## Ingest Service Key Details

- Auth: `POST /v1/ingest` requires `Authorization: Bearer <key>`. Lookup: `SELECT FROM api_keys WHERE key_sha256 = sha256hex AND revoked_at IS NULL`.
- Bulk insert uses `pgx` COPY protocol (10–50x faster than individual INSERTs). For idempotency with COPY: insert into a temp table, then `INSERT ... SELECT ... ON CONFLICT DO NOTHING`.
- Rate limits: 1,000 events/device/hour and 100 requests/key/minute. Return `429` with `Retry-After` header; the SDK backs off without marking events as failed.
- Clock skew: reject events where `occurred_at > now + 5min` or `occurred_at < now - 7 days`.
- Partial acceptance: valid events in a batch are stored even if some are malformed. Response: `{"accepted": N, "rejected": M, "errors": [{index, reason}]}`.

## iOS SDK Key Details

- **No third-party dependencies.** Use only: Foundation, Network, StoreKit, SQLite3 (system C lib via `-lsqlite3`), Security (Keychain), CryptoKit.
- **Minimum deployment target: iOS 15** (required for StoreKit 2 and async/await).
- All SQLite calls must be serialized on a dedicated `DispatchQueue` — never call SQLite from multiple threads.
- Crash handlers (`sigaction` + `NSSetUncaughtExceptionHandler`) must use only async-signal-safe operations: no `malloc`, no ObjC, no ARC. Pre-allocate a 64KB static buffer at init time. Use `write()` syscall only.
- `device_id` is a UUID stored in Keychain with `kSecAttrAccessibleAfterFirstUnlock`. Service: `"io.monitoor.sdk"`.
- `Monitoor.swift` is the only public-facing file. Everything else is `internal`.
- SQLite buffer path: `Library/monitoor_buffer.db`. Mark excluded from iCloud backup.

## Database

- `events` is the only billion-row table. It is partitioned by `occurred_at` (monthly). Add a new partition before each month starts — automate with a cron job on EC2.
- FK constraints are omitted on the partitioned `events` table (Postgres limitation pre-16).
- GDPR deletion path: `DELETE FROM events/sessions/revenue_events WHERE app_id = $1 AND device_id = $2`. `device_id` is a UUID with no link to real identity.

## Implementation Order

Follow phases in PLAN.md Part 8: Database → Ingest Service → SDK Foundation → SDK Capture → EC2 Deployment → Hardening. Each phase produces something independently testable.
