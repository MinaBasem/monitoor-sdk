#!/usr/bin/env python3
"""
Monitoor Ingest Service — AWS Lambda Handler
---------------------------------------------
Drop-in Lambda deployment of the ingest service.
Requires no third-party packages — only Python 3 stdlib + the Neon HTTP SQL API.

Environment variables (set in Lambda console or CloudFormation template):
    NEON_URL                  Neon HTTP SQL endpoint
    NEON_CONNECTION_STR       Full postgres:// connection string
    NEON_API_KEY              Neon API key (required only if NEON_SUSPEND_AFTER_INGEST=true)
    NEON_SUSPEND_AFTER_INGEST Set to "true" to suspend Neon compute after each successful
                              ingest. Best suited for low-traffic or dev environments.
                              See LAMBDA.md for concurrency trade-offs before enabling.
"""

import base64
import json
import os
import urllib.request
import urllib.error
import gzip
from datetime import datetime, timezone

# ── Configuration ──────────────────────────────────────────────────────────────

NEON_URL  = os.environ.get("NEON_URL")
NEON_CONN = os.environ.get("NEON_CONNECTION_STR")
NEON_API_KEY = os.environ.get("NEON_API_KEY", "")
NEON_SUSPEND_AFTER_INGEST = os.environ.get("NEON_SUSPEND_AFTER_INGEST", "false").lower() == "true"

NEON_PROJECT_ID  = "sweet-silence-19487365"
NEON_ENDPOINT_ID = "ep-shiny-hat-al5rb3wf"
NEON_SUSPEND_URL = (
    f"https://console.neon.tech/api/v2/projects/{NEON_PROJECT_ID}"
    f"/endpoints/{NEON_ENDPOINT_ID}/suspend"
)

if not NEON_URL or not NEON_CONN:
    raise RuntimeError(
        "NEON_URL and NEON_CONNECTION_STR environment variables must be set. "
        "Configure them in the Lambda function environment variables."
    )

MAX_BATCH_SIZE     = 200
MAX_FUTURE_SECONDS = 300   # reject events > 5 min in the future
MAX_AGE_DAYS       = 7     # reject events > 7 days old

# ── Database helpers ───────────────────────────────────────────────────────────

def neon_query(sql, params=None):
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
    try:
        neon_query(
            'UPDATE "ApiKey" SET "lastUsedAt" = NOW() WHERE id = $1',
            [api_key_id]
        )
    except Exception:
        pass


# ── Event validation ───────────────────────────────────────────────────────────

def validate_event(event, api_key_row, index):
    if not event.get("name"):
        return f"index {index}: missing name"
    if not event.get("device_id"):
        return f"index {index}: missing device_id"
    if not event.get("occurred_at"):
        return f"index {index}: missing occurred_at"
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
    Returns (status_code, response_dict). All DB writes are complete before returning.
    """
    try:
        payload = json.loads(body_bytes)
    except json.JSONDecodeError:
        return 400, {"error": "invalid JSON body"}

    batch = payload.get("batch", [])
    if not batch:
        return 400, {"error": "empty batch"}
    if len(batch) > MAX_BATCH_SIZE:
        return 400, {"error": f"batch exceeds maximum size of {MAX_BATCH_SIZE}"}

    try:
        api_key, err = lookup_api_key(bearer_token)
    except Exception as e:
        print(f"[auth error] {e}")
        return 500, {"error": "database error during authentication"}

    if err:
        return 401, {"error": err}

    environment = api_key.get("env", "development")
    api_key_id  = api_key["id"]

    accepted = 0
    rejected = 0
    errors   = []

    for i, event in enumerate(batch):
        validation_error = validate_event(event, api_key, i)
        if validation_error:
            errors.append({"index": i, "reason": validation_error})
            rejected += 1
            continue

        ctx             = event.get("context", {})
        occurred_at     = event["occurred_at"]
        idempotency_key = event.get("idempotency_key")
        properties      = event.get("properties")

        try:
            neon_query(
                '''
                INSERT INTO "Event" (
                    "apiKeyId", name, properties,
                    "sessionId", "deviceId", "userIdHash", "idempotencyKey",
                    "appVersion", "osVersion", "deviceModel",
                    environment, "occurredAt"
                ) VALUES (
                    $1, $2, $3,
                    $4, $5, $6, $7,
                    $8, $9, $10,
                    $11, $12
                )
                ON CONFLICT ("idempotencyKey") DO NOTHING
                ''',
                [
                    api_key_id,
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
            print(f"[insert error] event {i} ({event.get('name')}): {e}")
            errors.append({"index": i, "reason": "database insert failed"})
            rejected += 1

    update_last_used(api_key_id)

    return 200, {"accepted": accepted, "rejected": rejected, "errors": errors}


# ── Neon compute suspend ───────────────────────────────────────────────────────

def neon_suspend():
    """
    Suspend the Neon compute endpoint via the Neon Management API.

    Called synchronously after all DB writes have committed, so data is never lost.
    Neon ignores this request if the endpoint is already idle.

    Important: only enable NEON_SUSPEND_AFTER_INGEST in low-concurrency environments.
    If two Lambda invocations overlap, one may suspend the DB while the other is
    mid-write. Neon's built-in auto-suspend (5-minute idle timeout) is the safer
    alternative for production traffic.
    """
    if not NEON_API_KEY:
        print("[suspend] NEON_API_KEY not set — skipping suspend")
        return
    try:
        req = urllib.request.Request(
            NEON_SUSPEND_URL,
            data=b"",
            method="POST",
            headers={
                "accept": "application/json",
                "authorization": f"Bearer {NEON_API_KEY}",
            }
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            print(f"[suspend] Neon compute suspended (HTTP {resp.status})")
    except Exception as e:
        print(f"[suspend] Failed to suspend Neon compute: {e}")


# ── Lambda entry point ─────────────────────────────────────────────────────────

def lambda_handler(event, context):
    """
    AWS Lambda handler — receives API Gateway proxy events.

    API Gateway transforms every HTTP request into a structured event dict before
    invoking this function. This handler unpacks that dict, routes by method + path,
    and returns a dict that API Gateway converts back into an HTTP response.
    """
    method  = event.get("httpMethod", "")
    path    = event.get("path", "")
    # Normalise header keys to lowercase for case-insensitive lookup
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}

    # Decode body — API Gateway base64-encodes binary payloads
    raw = event.get("body") or ""
    body_bytes = base64.b64decode(raw) if event.get("isBase64Encoded") else raw.encode()
    if headers.get("content-encoding") == "gzip":
        try:
            body_bytes = gzip.decompress(body_bytes)
        except Exception:
            return _resp(400, {"error": "failed to decompress body"})

    # All routes require a Bearer token
    auth = headers.get("authorization", "")
    if not auth.startswith("Bearer "):
        return _resp(401, {"error": "missing or invalid Authorization header"})
    bearer_token = auth[len("Bearer "):]

    # ── Route ─────────────────────────────────────────────────────────────────

    if method == "GET" and path == "/health":
        try:
            neon_query("SELECT 1")
            return _resp(200, {"status": "ok", "db": "connected"})
        except Exception as e:
            return _resp(503, {"status": "error", "db": str(e)})

    if method == "POST" and path == "/v1/ingest":
        status, body = handle_ingest(bearer_token, body_bytes)
        print(f"[ingest] accepted={body.get('accepted', 0)} rejected={body.get('rejected', 0)}")
        response = _resp(status, body)
        # Suspend Neon compute only after all writes have successfully committed.
        # The function blocks here — Lambda does not return until suspend completes.
        if status == 200 and NEON_SUSPEND_AFTER_INGEST:
            neon_suspend()
        return response

    if method == "POST" and path == "/v1/crashes":
        return _resp(200, {"crash_id": "not_stored", "symbolicated": False})

    return _resp(404, {"error": "not found"})


def _resp(status, data):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(data),
    }
