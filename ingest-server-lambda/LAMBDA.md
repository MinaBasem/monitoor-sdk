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
3. **`handler.lambda_handler`** unpacks the event, authenticates the API key against the Neon `ApiKey` table, validates each event, and inserts accepted events one-by-one via Neon's HTTP SQL API — using `ON CONFLICT ("idempotencyKey") DO NOTHING` for safe retries.
4. Once all writes have committed, the function optionally suspends the Neon compute endpoint (see below), then returns a response dict which API Gateway converts back into an HTTP response.

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
| `NEON_API_KEY` | Conditional | Neon Management API key. Only required when `NEON_SUSPEND_AFTER_INGEST=true`. Obtain from **console.neon.tech → Account → API Keys → New Key**. |
| `NEON_SUSPEND_AFTER_INGEST` | No | Set to `"true"` to suspend the Neon compute endpoint after each successful ingest. Default: `"false"`. Read the section below before enabling. |

Set these in the Lambda console (**Configuration → Environment variables**) or via the CloudFormation parameters in `template.yaml`. They are never written to disk or logged.

---

## Neon Compute Suspend

When `NEON_SUSPEND_AFTER_INGEST=true`, the Lambda calls the Neon Management API to suspend the compute endpoint **after all DB writes have committed and before the HTTP response is returned**. This guarantees:

- No data loss — writes complete first, suspend request is made second.
- The iOS SDK sees a normal `200` response either way; the suspend step is invisible to callers.
- Neon silently ignores the suspend request if the endpoint is already idle.

### When to enable

| Scenario | Recommendation |
|---|---|
| Development / staging with very low traffic | **Enable** — aggressively minimises compute billing when idle |
| Production with steady or bursty traffic | **Disable** — use Neon's built-in 5-minute auto-suspend instead |

### Concurrency trade-off

Lambda scales by running **parallel invocations**, not threads. If two requests arrive simultaneously, Lambda A and Lambda B each run as independent function instances. If Lambda A calls suspend while Lambda B is mid-write, Neon will stop the compute immediately and Lambda B's in-flight query will fail with a connection error.

**Mitigation options:**
- Keep `NEON_SUSPEND_AFTER_INGEST=false` in production and rely on Neon's auto-suspend (5-minute idle timeout is already low cost).
- Reserve `NEON_SUSPEND_AFTER_INGEST=true` for environments where concurrent requests are rare or impossible (e.g., a single-developer staging environment, or a scheduled batch trigger rather than real-time HTTP traffic).

The Neon auto-suspend timeout can be managed from `ingest-server/NEON.md`.

---

## Deployment

### Prerequisites

- [AWS SAM CLI](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html) installed
- AWS credentials configured (`aws configure` or environment variables)
- A Neon project with the Monitoor schema already applied

### Deploy

```bash
cd ingest-server-lambda

# Build (packages handler.py into a deployment artifact)
sam build

# Deploy interactively — prompts for parameters on first run, saves to samconfig.toml
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
| Neon suspend | Not applicable | Optional via `NEON_SUSPEND_AFTER_INGEST` |
| Deployment | EC2 / any server with Python 3 | AWS Lambda + API Gateway via SAM |
| Business logic | Identical | Identical (same functions, same SQL) |

Both deployments talk to the same Neon database and are interchangeable from the iOS SDK's perspective.
