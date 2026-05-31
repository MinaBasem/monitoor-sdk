# Neon Compute — On / Off

Your Neon identifiers:

| Field | Value |
|---|---|
| Project ID | `sweet-silence-19487365` |
| Endpoint ID | `ep-shiny-hat-al5rb3wf` |
| API key | Get from: console.neon.tech → Account → API Keys → New Key |

Export your key once so the commands below work directly:

```bash
export NEON_API_KEY=your_api_key_here
```

---

## Suspend (turn off compute)

Stops the compute immediately. Your data is untouched. No compute billing until you resume.

```bash
curl --request POST \
  --url "https://console.neon.tech/api/v2/projects/sweet-silence-19487365/endpoints/ep-shiny-hat-al5rb3wf/suspend" \
  --header "accept: application/json" \
  --header "authorization: Bearer $NEON_API_KEY"
```

---

## Resume (turn on compute)

Starts the compute again. Takes ~1–2 seconds.

```bash
curl --request POST \
  --url "https://console.neon.tech/api/v2/projects/sweet-silence-19487365/endpoints/ep-shiny-hat-al5rb3wf/start" \
  --header "accept: application/json" \
  --header "authorization: Bearer $NEON_API_KEY"
```

---

## Check current state

```bash
curl --request GET \
  --url "https://console.neon.tech/api/v2/projects/sweet-silence-19487365/endpoints/ep-shiny-hat-al5rb3wf" \
  --header "accept: application/json" \
  --header "authorization: Bearer $NEON_API_KEY" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('state:', d['endpoint']['current_state'])"
```

Possible states: `idle` (suspended) · `active` (running) · `init` (starting up)

---

## Disable auto-suspend (stay on until manually suspended)

By default Neon auto-suspends after 5 minutes of inactivity. Set `suspend_timeout_seconds` to `-1` to disable that:

```bash
curl --request PATCH \
  --url "https://console.neon.tech/api/v2/projects/sweet-silence-19487365/endpoints/ep-shiny-hat-al5rb3wf" \
  --header "accept: application/json" \
  --header "authorization: Bearer $NEON_API_KEY" \
  --header "content-type: application/json" \
  --data '{ "endpoint": { "suspend_timeout_seconds": -1 } }'
```

---

## Re-enable auto-suspend (suspend after 5 minutes idle)

```bash
curl --request PATCH \
  --url "https://console.neon.tech/api/v2/projects/sweet-silence-19487365/endpoints/ep-shiny-hat-al5rb3wf" \
  --header "accept: application/json" \
  --header "authorization: Bearer $NEON_API_KEY" \
  --header "content-type: application/json" \
  --data '{ "endpoint": { "suspend_timeout_seconds": 300 } }'
```

---

## Notes

- Suspending compute does **not** delete any data — the `Event`, `ApiKey`, and `User` tables are always safe
- The ingest server will get a ~1–2 second delay on the first query after a cold start — the SDK handles this transparently via its retry logic
- While compute is suspended, the ingest server's health check (`/health`) will appear slow but recover automatically once Neon wakes up
