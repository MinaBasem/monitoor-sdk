#!/usr/bin/env python3
"""
Monitoor Ingest Service — AWS Lambda Handler
---------------------------------------------
Drop-in Lambda deployment of the ingest service.
Requires no third-party packages — only Python 3 stdlib + the Neon HTTP SQL API.

Environment variables (set in Lambda console or CloudFormation template):
    NEON_URL             Neon HTTP SQL endpoint
    NEON_CONNECTION_STR  Full postgres:// connection string
    NEON_API_KEY         Neon Management API key — used to suspend compute when
                         the last active Lambda invocation finishes. Obtain from:
                         console.neon.tech → Account → API Keys.
                         If not set, suspend is skipped and Neon auto-suspends
                         after its built-in idle timeout (5 min on free tier).
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
        '"captureRevenue", "captureScreens", "captureHeatmaps", "captureRecordings", '
        'mul, retention '
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


def handle_config(bearer_token):
    """
    Process a GET /v1/config request.
    Returns (status_code, response_dict) with the ApiKey's capture configuration.
    """
    try:
        api_key, err = lookup_api_key(bearer_token)
    except Exception as e:
        print(f"[config auth error] {e}")
        return 500, {"error": "database error during authentication"}

    if err:
        return 401, {"error": err}

    return 200, {
        "captureEvents":     api_key.get("captureEvents", True),
        "captureScreens":    api_key.get("captureScreens", True),
        "captureRevenue":    api_key.get("captureRevenue", True),
        "captureCrashes":    api_key.get("captureCrashes", True),
        "captureHeatmaps":   api_key.get("captureHeatmaps", False),
        "captureRecordings": api_key.get("captureRecordings", False),
        "mul":               api_key.get("mul", 1.0),
        "retention":         api_key.get("retention", 90),
    }




# ── Lambda concurrency tracking ────────────────────────────────────────────────

def _increment_active():
    """
    Register this Lambda invocation in the shared counter stored in Neon.
    Called at the very start of every invocation — including rejected ones —
    so the count accurately reflects all in-flight Lambdas.
    """
    try:
        neon_query("UPDATE lambda_concurrency SET active = active + 1")
    except Exception as e:
        print(f"[concurrency] increment failed: {e}")


def _decrement_active():
    """
    Decrement the active counter.
    GREATEST(..., 0) prevents the counter going negative if a prior invocation
    crashed before decrementing (e.g. Lambda timeout, OOM kill).
    Neon compute is left to auto-suspend via its built-in idle timeout —
    suspending it synchronously here would block the HTTP response to the SDK.
    """
    try:
        result = neon_query(
            "UPDATE lambda_concurrency SET active = GREATEST(active - 1, 0) RETURNING active"
        )
        remaining = result["rows"][0]["active"]
        print(f"[concurrency] active invocations remaining: {remaining}")
    except Exception as e:
        print(f"[concurrency] decrement failed: {e}")


# ── Lambda entry point ─────────────────────────────────────────────────────────

def lambda_handler(event, context):
    """
    AWS Lambda handler — receives API Gateway proxy events.

    Increments the shared active-invocation counter at the start and decrements
    it at the end (via finally, so crashes don't leave the counter stuck).
    The last invocation to finish — the one that brings the counter to 0 —
    suspends the Neon compute endpoint.
    """
    _increment_active()
    try:
        method  = event.get("httpMethod", "")
        path    = event.get("path", "")
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

        if method == "GET" and path == "/health":
            try:
                neon_query("SELECT 1")
                return _resp(200, {"status": "ok", "db": "connected"})
            except Exception as e:
                return _resp(503, {"status": "error", "db": str(e)})

        if method == "GET" and path == "/v1/config":
            status, body = handle_config(bearer_token)
            return _resp(status, body)

        if method == "POST" and path == "/v1/ingest":
            status, body = handle_ingest(bearer_token, body_bytes)
            print(f"[ingest] accepted={body.get('accepted', 0)} rejected={body.get('rejected', 0)}")
            return _resp(status, body)

        if method == "POST" and path == "/v1/crashes":
            return _resp(200, {"crash_id": "not_stored", "symbolicated": False})

        return _resp(404, {"error": "not found"})

    finally:
        # Always runs — even on unhandled exceptions — so the counter never
        # gets permanently stuck from a crashed invocation.
        _decrement_active()


def _resp(status, data):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(data),
    }
