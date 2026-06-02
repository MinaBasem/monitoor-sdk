# Monitoor Ingest — AWS Lambda Deployment

This directory contains a self-contained AWS Lambda deployment of the Monitoor ingest service. It is a parallel deployment path alongside `ingest-server/server.py` — both speak the same API, the same Neon database, and the same wire format understood by the iOS SDK.

---

## How It Works

```
iOS SDK  ──HTTPS──►  API Gateway  ──event dict──►  Lambda (handler.py)
                                                         │
                                                  Neon HTTP SQL API
                                                         │
                                                   Neon PostgreSQL
```

1. The iOS SDK sends a `POST /v1/ingest` request with a JSON batch of events and a `Bearer` API key.
2. **API Gateway** receives the request, wraps it into a structured event dict (method, path, headers, body, base64 flag), and invokes the Lambda function synchronously.
3. **`handler.lambda_handler`** increments a shared `active` counter in Neon, then authenticates the API key, validates each event, and inserts accepted events one-by-one via Neon's HTTP SQL API — using `ON CONFLICT ("idempotencyKey") DO NOTHING` for safe retries.
4. Once all writes have committed, the function decrements the counter. If the counter reaches 0 (this is the last active invocation), it suspends the Neon compute endpoint. The response dict is then returned and API Gateway converts it back into an HTTP response.

The function uses **only Python 3 stdlib** (`json`, `urllib`, `gzip`, `base64`, `datetime`) — no third-party dependencies and no layers needed.

---

## Why API Gateway Is Required

Lambda functions are **not directly reachable over the internet**. They are invoked either:
- programmatically via the AWS SDK/CLI (`aws lambda invoke …`), or
- through an AWS trigger like **API Gateway**, which acts as the public HTTPS frontend.

API Gateway is what gives the Lambda function a stable HTTPS URL that the iOS SDK can call. Specifically it handles:

| Concern | API Gateway's role |
|---|---|
| **Public URL** | Provides a stable `https://<id>.execute-api.<region>.amazonaws.com/<stage>/…` endpoint |
| **TLS termination** | All traffic is HTTPS; API Gateway holds the certificate |
| **HTTP-to-Lambda translation** | Converts raw HTTP requests into the structured event dict that `lambda_handler` receives |
| **Lambda-to-HTTP translation** | Converts the `{"statusCode", "headers", "body"}` dict returned by `lambda_handler` back into an HTTP response |
| **Throttling** | The `template.yaml` sets a burst limit of 200 req/s and a steady-state rate of 100 req/s — misuse is rejected at the gateway before Lambda is invoked |
| **Request size limit** | API Gateway enforces a 10 MB payload cap (well above any realistic event batch) |

Without API Gateway, the Lambda function is unreachable from the iOS SDK.

---

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `NEON_URL` | **Yes** | Neon HTTP SQL endpoint URL. Find it in the Neon console under your project → Connection Details → HTTP endpoint. Example: `https://ep-shiny-hat-al5rb3wf.neon.tech/sql` |
| `NEON_CONNECTION_STR` | **Yes** | Full `postgresql://` connection string, including password. Passed as the `Neon-Connection-String` header on every SQL request. Example: `postgresql://neondb_owner:pass@ep-xxx.neon.tech/neondb?sslmode=require` |
| `NEON_API_KEY` | No | Neon Management API key. When set, the last active Lambda invocation automatically suspends Neon compute after all writes complete. Obtain from **console.neon.tech → Account → API Keys → New Key**. If not set, Neon falls back to its built-in idle timeout (5 minutes on the free tier). |

Set these in the Lambda console (**Configuration → Environment variables**) or via the CloudFormation parameters in `template.yaml`. They are never written to disk or logged.

---

## Neon Compute Suspend

### Prerequisites

Before deploying, run `schema.sql` once against your Neon database:

```bash
psql "$NEON_CONNECTION_STR" -f schema.sql
```

This creates the `lambda_concurrency` table — a single row with an `active` integer counter that all Lambda invocations share.

### How it works

Every Lambda invocation increments the counter when it starts and decrements it when it finishes (via a `finally` block, so crashes don't leave it stuck). The invocation that brings the counter to **0** is the last one running — it waits 2 seconds to let any Lambda that started in the same instant register itself, rechecks the count, and if still 0 calls the Neon suspend API.

```
Lambda A starts   →  active = 1
Lambda B starts   →  active = 2
Lambda C starts   →  active = 3

Lambda B finishes →  active = 2  → others still running, exit
Lambda A finishes →  active = 1  → others still running, exit
Lambda C finishes →  active = 0  → last one → wait 2s → recheck → suspend Neon
```

The 2-second wait closes the race window where Lambda D could start in the same instant Lambda C decrements to 0. After the wait, Lambda C rechecks: if Lambda D registered, the count is 1 and Lambda C exits without suspending.

### Guarantees

- **No data loss** — all writes complete before the counter is decremented; suspend is called after.
- **No stuck counter** — `finally` ensures decrement runs even if the handler throws. `GREATEST(active - 1, 0)` prevents the counter going negative from any edge case.
- **Safe on Neon free tier** — Neon silently ignores suspend requests on already-idle endpoints. If `NEON_API_KEY` is not set, suspension is skipped entirely and Neon falls back to its 5-minute idle timeout.

### Manual reset

If a Lambda is killed by an AWS infrastructure event (rare), the counter may be left above 0. Reset it manually:

```sql
UPDATE lambda_concurrency SET active = 0;
```

---

## Deployment

### Prerequisites

- [AWS SAM CLI](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html) installed
- AWS credentials configured (`aws configure` or environment variables)
- A Neon project with the Monitoor schema already applied

### Deploy

```bash
cd ingest-server-lambda

# 1. Run the schema migration once against your Neon database
psql "$NEON_CONNECTION_STR" -f schema.sql

# 2. Build (packages handler.py into a deployment artifact)
sam build

# 3. Deploy interactively — prompts for parameters on first run, saves to samconfig.toml
sam deploy --guided
```

When prompted, supply:
- `NeonUrl` — your Neon HTTP SQL endpoint
- `NeonConnectionStr` — your Neon connection string
- `NeonApiKey` — leave blank unless enabling suspend
- `NeonSuspendAfterIngest` — `false` (default) or `true`
- `StageName` — `prod`, `staging`, etc.

On completion, SAM prints the `ApiBaseUrl` output. Use this as `ingestURL` in the iOS SDK.

### Subsequent deploys

```bash
sam build && sam deploy
```

### Local testing (no AWS account needed)

```bash
# Copy and fill in your values
cp .env.example .env

# Start a local API Gateway + Lambda emulator
sam local start-api --env-vars .env

# Test
curl -X POST http://localhost:3000/v1/ingest \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"batch": [{"name": "test", "device_id": "abc", "occurred_at": "2026-06-02T12:00:00Z", "idempotency_key": "k1"}]}'

curl http://localhost:3000/health \
  -H "Authorization: Bearer YOUR_API_KEY"
```

---

## Differences from `ingest-server/server.py`

| Aspect | `server.py` | `handler.py` (Lambda) |
|---|---|---|
| Entry point | `httpd.serve_forever()` long-running process | `lambda_handler(event, context)` per-request function |
| Concurrency | `ThreadingMixIn` — multiple threads per process | Multiple Lambda instances — one thread per instance |
| `.env` file | Loaded automatically from disk | Not used — env vars set in Lambda console / CloudFormation |
| Neon suspend | Not applicable | Automatic — last active invocation suspends via shared counter |
| Deployment | EC2 / any server with Python 3 | AWS Lambda + API Gateway via SAM |
| Business logic | Identical | Identical (same functions, same SQL) |

Both deployments talk to the same Neon database and are interchangeable from the iOS SDK's perspective.
