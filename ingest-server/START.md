# Starting the Ingest Server

## Prerequisites

- Your Mac and iPhone must be on the **same Wi-Fi network**
- `ingest-server/.env` must exist with valid Neon credentials

## Start

```bash
cd ~/Library/Mobile\ Documents/com~apple~CloudDocs/Monitoor/monitoor-sdk/ingest-server
python3 server.py
```

Expected output:

```
Monitoor ingest service running on port 8080
  POST http://localhost:8080/v1/ingest
  GET  http://localhost:8080/health
  Database: Neon (neondb)
```

## Verify it's working

Open a second Terminal tab and run:

```bash
curl http://localhost:8080/health
```

Expected response:

```json
{ "status": "ok", "db": "connected" }
```

## Stop

Press `Control + C` in the Terminal window where the server is running.

## If port 8080 is already in use

```bash
lsof -ti:8080 | xargs kill -9
```

Then start again with `python3 server.py`.

## Checking events in the database

```bash
python3 << 'EOF'
import urllib.request, json
from pathlib import Path

env = {}
for line in open(Path.home() / "Library/Mobile Documents/com~apple~CloudDocs/Monitoor/monitoor-sdk/ingest-server/.env"):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, _, v = line.partition("=")
        env[k.strip()] = v.strip()

body = json.dumps({"query": 'SELECT name, properties, "occurredAt" FROM "Event" ORDER BY "receivedAt" DESC LIMIT 20'}).encode()
req = urllib.request.Request(env["NEON_URL"], data=body, headers={
    "Content-Type": "application/json",
    "Neon-Connection-String": env["NEON_CONNECTION_STR"]
})
with urllib.request.urlopen(req, timeout=10) as r:
    rows = json.loads(r.read())["rows"]
print(f"{len(rows)} most recent events:\n")
for row in rows:
    print(f"  {row['name']:<35} {row['occurredAt']}  props={row['properties']}")
EOF
```

## Notes

- The server reads credentials from `.env` automatically — no `source .env` needed
- In development, `NusicaApp.swift` must have `ingestURL` set to `http://YOUR_MAC_IP:8080`
- Your Mac's current local IP: run `ipconfig getifaddr en0` in Terminal
- The server must be running whenever you test the app — events that fail to send are buffered on the device and retried automatically when the server is back up
