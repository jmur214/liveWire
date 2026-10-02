# SETUP — values only you can supply

Everything the build could not know is a clearly named placeholder. Fill each
one in the place listed, then follow the steps at the bottom.

## Placeholders

| Placeholder | Where | What it is / how to get it |
|---|---|---|
| `REPLACE_ME_STREAM_URL` | `/opt/livewire/.env` → `STREAM_URL` (template: `deploy/.env.example`) | Raw audio URL for Broadcastify feed 14395 (Premium account), or the stream the Lincoln 911 Center gives you. Any ffmpeg-readable URL works. |
| `REPLACE_ME_GROQ_API_KEY` | `.env` → `GROQ_API_KEY` | console.groq.com → API Keys. (Or set `TRANSCRIBER=openai` and `OPENAI_API_KEY`.) |
| `REPLACE_ME_ANTHROPIC_API_KEY` | `.env` → `ANTHROPIC_API_KEY` | console.anthropic.com → API Keys. Used by `extract.py` (Claude Haiku). |
| `REPLACE_ME_API_TOKEN` | `.env` → `API_TOKEN` **and** the app: Settings → Server → API token | Any long random string. `deploy/install.sh` generates one for you and prints it; paste the same value into the app. |
| `REPLACE_ME_APNS_KEY_ID` | `.env` → `APNS_KEY_ID` | developer.apple.com → Certificates, Identifiers & Profiles → Keys → create a key with *Apple Push Notifications service (APNs)*. The 10-character Key ID. |
| `REPLACE_ME_TEAM_ID` | `.env` → `APNS_TEAM_ID` **and** `ios/project.yml` → `DEVELOPMENT_TEAM` | Your Apple Developer Team ID (Membership page). |
| `REPLACE_ME_BUNDLE_PREFIX` | `ios/project.yml` → `bundleIdPrefix` and `PRODUCT_BUNDLE_IDENTIFIER` (two targets); `.env` → `APNS_BUNDLE_ID` | Reverse-DNS prefix, e.g. `com.yourname`. The bundle ID becomes `com.yourname.livewire` and must match `APNS_BUNDLE_ID` exactly. |
| `REPLACE_ME_SERVER_HOST` | `ios/LiveWire/Services/Settings.swift` → `defaultServerURL` (Release default only) | Your domain, e.g. `https://scanner.example.com`. Debug builds default to `http://localhost:8000`; the URL is also editable in-app. |
| `REPLACE_ME_DOMAIN` | `deploy/Caddyfile` (installed to `/etc/caddy/Caddyfile`) | The domain pointed at the VPS. `deploy/install.sh <domain>` fills it in for you. |
| APNs `.p8` key file | Copy to `/opt/livewire/apns.p8` (path in `.env` → `APNS_KEY_PATH`) | Downloaded once when you create the APNs key above. Never commit it. |
| `MAPBOX_TOKEN` (optional) | `.env` → `GEOCODER=mapbox`, `MAPBOX_TOKEN` | Much better intersection/business geocoding than Nominatim. |

`APNS_SANDBOX` in `.env` is only a fallback: each app build tells the server
whether it is a Debug (sandbox APNs) or Release (production APNs) build.

## Steps

1. **VPS** (Ubuntu 24.04, 1–2 vCPU, 2 GB). Point your domain's A record at it.
   ```bash
   git clone <this repo> livewire && cd livewire
   sudo bash deploy/install.sh scanner.example.com
   ```
   The script installs ffmpeg/python/caddy/espeak-ng, creates `/opt/livewire`
   with a venv, writes `/opt/livewire/.env` with a random `API_TOKEN`, starts
   `livewire-api` and `livewire-ingest`, and configures Caddy for HTTPS.
2. **Fill `/opt/livewire/.env`**: `STREAM_URL`, `GROQ_API_KEY`,
   `ANTHROPIC_API_KEY`, the `APNS_*` values; copy the `.p8` to
   `/opt/livewire/apns.p8` (`chown livewire:livewire`, `chmod 600`). Then
   `sudo systemctl restart livewire-ingest livewire-api`.
3. **Check the server**:
   ```bash
   curl -H "Authorization: Bearer <API_TOKEN>" https://scanner.example.com/api/health
   journalctl -u livewire-ingest -f        # transcripts should scroll by
   ```
   Open `https://scanner.example.com/` for the Leaflet smoke-test map (it asks
   for the token once).
4. **Xcode project**: `brew install xcodegen`, edit `ios/project.yml`
   (`REPLACE_ME_TEAM_ID`, `REPLACE_ME_BUNDLE_PREFIX`) and
   `ios/LiveWire/Services/Settings.swift` (`REPLACE_ME_SERVER_HOST`), then
   ```bash
   cd ios && xcodegen generate && open LiveWire.xcodeproj
   ```
   Xcode 16, iOS 17 deployment target. Signing is automatic with your team.
   Capabilities (Background Modes: Audio + Location updates; Push
   Notifications) come from `Info.plist` / `LiveWire.entitlements` — enable
   Push Notifications for the App ID in the developer portal if Xcode asks.
5. **Run against the replay server first** (no keys needed):
   ```bash
   uvicorn server:app --port 8000 &            # API_TOKEN unset → "dev-token"
   python main.py --replay tests/fixtures/lincoln_day.json --speed 10 --loop
   ```
   Run the Debug scheme in the simulator: it defaults to
   `http://localhost:8000`; enter `dev-token` in Settings → Server → API token
   and tap Test.
6. **Install on the phone** (Xcode → your device, or TestFlight with an
   archive). In the app: Settings → Server → your `https://` URL and the
   `API_TOKEN` from step 1 → Test. Turn on Alerts to register for push; the
   server's `devices` table gets a row within a few seconds.
7. **Optional**: `GEOCODER=mapbox MAPBOX_TOKEN=…` for better geocoding;
   `TRANSCRIBER=local` plus `pip install -r requirements-local-whisper.txt` to
   run Whisper on the box instead of Groq (needs more RAM/CPU).
