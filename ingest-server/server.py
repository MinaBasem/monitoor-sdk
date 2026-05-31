#!/usr/bin/env python3
"""
Monitoor Ingest Service
-----------------------
Receives events from the iOS SDK and writes them to the Neon PostgreSQL database.
Requires no third-party packages — only Python 3 stdlib + the Neon HTTP SQL API.

Usage:
    python3 server.py

Environment variables (optional, override the defaults below):
    PORT                 HTTP port to listen on (default: 8080)
    NEON_URL             Neon HTTP SQL endpoint
    NEON_CONNECTION_STR  Full postgres:// connection string
"""

import http.server
import json
import os
import urllib.request
import urllib.error
import gzip
import socketserver
from datetime import datetime, timezone

# ── Configuration ─────────────────────────────────────────────────────────────

PORT = int(os.environ.get("PORT", "8080"))

NEON_URL  = os.environ.get("NEON_URL")
NEON_CONN = os.environ.get("NEON_CONNECTION_STR")

if not NEON_URL or not NEON_CONN:
    raise RuntimeError(
        "Missing required environment variables.\n"
        "Copy .env.example to .env and fill in your Neon credentials,\n"
        "then run: source .env && python3 server.py"
    )

MAX_BATCH_SIZE = 200
MAX_FUTURE_SECONDS = 300   # reject events > 5 min in the future
MAX_AGE_DAYS = 7           # reject events > 7 days old

# ── Database helpers ───────────────────────────────────────────────────────────

def neon_query(sql, params=None):
    """Execute a SQL statement via the Neon HTTP API. Returns the parsed response dict."""
    payload = {"query": sql}
    if params:
        payload["params"] = params
    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        NEON_URL,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Neon-Connection-String": NEON_CONN,
        }
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read())


def lookup_api_key(bearer_token):
    """
    Verify the API key and return (api_key_row, error_message).
    Looks up by keyValue directly (the actual key stored in the ApiKey table).
    """
    result = neon_query(
        'SELECT id, "appName", "bundleId", env, "captureEvents", "captureCrashes", '
        '"captureRevenue", "captureScreens", mul, retention '
        'FROM "ApiKey" WHERE "keyValue" = $1 LIMIT 1',
        [bearer_token]
    )
    rows = result.get("rows", [])

    if not rows:
        return None, "invalid or revoked API key"

    return rows[0], None


def update_last_used(api_key_id):
    """Non-blocking best-effort update of lastUsedAt."""
    try:
        neon_query(
            'UPDATE "ApiKey" SET "lastUsedAt" = NOW() WHERE id = $1',
            [api_key_id]
        )
    except Exception:
        pass  # not critical


# ── Event validation ───────────────────────────────────────────────────────────

def validate_event(event, api_key_row, index):
    """Returns an error string or None if valid."""
    if not event.get("name"):
        return f"index {index}: missing name"
    if not event.get("device_id"):
        return f"index {index}: missing device_id"
    if not event.get("occurred_at"):
        return f"index {index}: missing occurred_at"

    # Clock-skew check
    try:
        occurred = datetime.fromisoformat(
            event["occurred_at"].replace("Z", "+00:00")
        )
        now = datetime.now(timezone.utc)
        delta = (occurred - now).total_seconds()
        if delta > MAX_FUTURE_SECONDS:
            return f"index {index}: occurred_at is too far in the future"
        if (now - occurred).total_seconds() > MAX_AGE_DAYS * 86400:
            return f"index {index}: occurred_at is too old"
    except (ValueError, TypeError):
        return f"index {index}: invalid occurred_at format"

    return None


# ── Ingest handler ─────────────────────────────────────────────────────────────

def handle_ingest(bearer_token, body_bytes):
    """
    Process a POST /v1/ingest request.
    Returns (status_code, response_dict).
    """
    # Parse body
    try:
        payload = json.loads(body_bytes)
    except json.JSONDecodeError:
        return 400, {"error": "invalid JSON body"}

    batch = payload.get("batch", [])
    if not batch:
        return 400, {"error": "empty batch"}
    if len(batch) > MAX_BATCH_SIZE:
        return 400, {"error": f"batch exceeds maximum size of {MAX_BATCH_SIZE}"}

    # Authenticate
    try:
        api_key, err = lookup_api_key(bearer_token)
    except Exception as e:
        print(f"  [auth error] {e}")
        return 500, {"error": "database error during authentication"}

    if err:
        return 401, {"error": err}

    environment = api_key.get("env", "development")
    api_key_id  = api_key["id"]
    app_name    = api_key.get("appName")
    bundle_id   = api_key.get("bundleId")

    # Validate and insert events
    accepted = 0
    rejected = 0
    errors = []

    for i, event in enumerate(batch):
        validation_error = validate_event(event, api_key, i)
        if validation_error:
            errors.append({"index": i, "reason": validation_error})
            rejected += 1
            continue

        # Extract context block
        ctx = event.get("context", {})
        occurred_at = event["occurred_at"]
        idempotency_key = event.get("idempotency_key")
        properties = event.get("properties")

        try:
            neon_query(
                '''
                INSERT INTO "Event" (
                    "apiKeyId", "appName", "bundleId", name, properties,
                    "sessionId", "deviceId", "userIdHash", "idempotencyKey",
                    "appVersion", "osVersion", "deviceModel",
                    environment, "occurredAt"
                ) VALUES (
                    $1, $2, $3, $4, $5,
                    $6, $7, $8, $9,
                    $10, $11, $12,
                    $13, $14
                )
                ON CONFLICT ("idempotencyKey") DO NOTHING
                ''',
                [
                    api_key_id,
                    app_name or ctx.get("bundle_id"),
                    bundle_id or ctx.get("bundle_id"),
                    event["name"],
                    json.dumps(properties) if properties else None,
                    event.get("session_id"),
                    event["device_id"],
                    event.get("user_id_hash"),
                    idempotency_key,
                    ctx.get("app_version"),
                    ctx.get("os"),
                    ctx.get("device"),
                    environment,
                    occurred_at,
                ]
            )
            accepted += 1
        except Exception as e:
            print(f"  [insert error] event {i} ({event.get('name')}): {e}")
            errors.append({"index": i, "reason": "database insert failed"})
            rejected += 1

    # Update last-used timestamp in the background
    update_last_used(api_key_id)

    return 200, {
        "accepted": accepted,
        "rejected": rejected,
        "errors": errors
    }


# ── HTTP request handler ───────────────────────────────────────────────────────

class IngestHandler(http.server.BaseHTTPRequestHandler):

    def log_message(self, format, *args):
        print(f"  [{self.client_address[0]}] {format % args}")

    def send_json(self, status, data):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            # Verify DB connectivity
            try:
                neon_query('SELECT 1')
                self.send_json(200, {"status": "ok", "db": "connected"})
            except Exception as e:
                self.send_json(503, {"status": "error", "db": str(e)})
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        # Read body (decompress gzip if needed)
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        if self.headers.get("Content-Encoding") == "gzip":
            try:
                raw = gzip.decompress(raw)
            except Exception:
                self.send_json(400, {"error": "failed to decompress body"})
                return

        # Parse Authorization header
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            self.send_json(401, {"error": "missing or invalid Authorization header"})
            return
        bearer_token = auth[len("Bearer "):]

        if self.path == "/v1/ingest":
            status, response = handle_ingest(bearer_token, raw)
            print(f"  ingest → accepted={response.get('accepted',0)} rejected={response.get('rejected',0)}")
            self.send_json(status, response)

        elif self.path == "/v1/crashes":
            # Crash reports accepted but not yet persisted (no Crash table yet)
            self.send_json(200, {"crash_id": "not_stored", "symbolicated": False})

        else:
            self.send_json(404, {"error": "not found"})


# ── Entry point ────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    # Allow port reuse so quick restarts don't hit "address already in use"
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("", PORT), IngestHandler) as httpd:
        print(f"Monitoor ingest service running on port {PORT}")
        print(f"  POST http://localhost:{PORT}/v1/ingest")
        print(f"  GET  http://localhost:{PORT}/health")
        print(f"  Database: Neon (neondb)")
        print()
        httpd.serve_forever()
