# LiveWire — Lincoln, NE police/fire radio on a live map

Open the app when you hear sirens; see what's happening and where within two
seconds. Listens to the public-safety audio feed, cuts it into transmissions,
transcribes each one, pulls out the location with Claude, geocodes it, groups
transmissions into **incidents**, and serves them to an iOS app (SwiftUI +
MapKit) and a Leaflet web map, with the original audio a tap away. Push
alerts fire for incident types or places you care about.

```
ffmpeg stream ─▶ VAD ─▶ transcribe ─▶ Claude extract ─▶ geocode ─▶ SQLite ─▶ incidents ─▶ alerts (APNs)
  ingest.py              transcribe.py  extract.py        geocode.py   db.py      incidents.py  push.py
                                                                          │
                                                   server.py: /api/incidents, /api/transmissions,
                                                   /api/stream (SSE), /audio, /api/device, static map
                                                                          │
                                                             ios/ (LiveWire app)   static/index.html
```

`DESIGN.md` is the spec (Part A what, Part B how). `DECISIONS.md` records
every call made where the spec was ambiguous. `SETUP.md` lists what you must
supply. `REPORT.md` is the build report.

## Quick start (no keys, no stream): replay mode

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
sudo apt install ffmpeg espeak-ng          # espeak-ng is optional (replay voices)

uvicorn server:app --port 8000 &           # API_TOKEN unset → dev token "dev-token"
python main.py --replay tests/fixtures/lincoln_day.json --speed 10 --loop
```

Open http://localhost:8000 (token `dev-token`) or run the iOS Debug scheme in
the simulator. The fixture is 90 simulated minutes of Lincoln traffic: ten
incidents across police, fire and sheriff with acknowledgements, a clock read
that calibrates the police delay, and some noise.

## Running for real

Set the values in `deploy/.env.example` (see `SETUP.md`), then:

```bash
python main.py                                   # ingest → transcribe → extract → incidents → alerts
uvicorn server:app --host 127.0.0.1 --port 8000  # API + web map (put Caddy in front for HTTPS)
```

or on a VPS: `sudo bash deploy/install.sh scanner.example.com` (Ubuntu 24.04).

## What you need to know about Lincoln specifically

* **The city's official feed is Broadcastify feed #14395** ("Lincoln Police and
  Fire, Lancaster County Sheriff"), linked from lincoln.ne.gov's 911 Center
  page. It mixes three agencies into one stream.
* **LPD audio on it is delayed** by an undisclosed, variable amount. All LPD
  talkgroups are encrypted over the air. `delay.py` watches for dispatchers
  reading the clock and back-dates police events; the app shows "Delayed ~N min".
* **Lincoln Fire & Rescue and the Sheriff are live and unencrypted** (P25
  Phase II). An RTL-SDR + trunk-recorder can replace the stream for them;
  point `--source` at its output.
* **Getting the stream URL.** Broadcastify exposes raw URLs to Premium
  subscribers only, and their terms prohibit rebroadcast. For a personal
  project, asking the Lincoln Emergency Communications Center for the source
  stream is the cleaner path. Put whatever you get in `STREAM_URL`.

## API (bearer token on every `/api/*` and `/audio/*` request)

| Endpoint | Purpose |
|---|---|
| `GET /api/health` | ok, version, city, `ingest_alive`, `police_delay_sec`, `last_transmission_at` |
| `GET /api/cities` | city config + the incident-type vocabulary |
| `GET /api/incidents?hours=2&agencies=police,fire` | incidents, newest first, with unit statuses |
| `GET /api/incidents/{id}` | one incident + its transmissions (timeline) |
| `GET /api/transmissions?since_id=&limit=` | raw feed, id ascending, pageable |
| `GET /api/stream` | SSE: `transmission`, `incident`, `ping` events |
| `GET /audio/{file}` | 16 kHz mono WAV clip |
| `POST /api/device` | APNs token + alert rules (evaluated server-side) |
| `POST /api/report` | flag an incident's location as wrong |

Full contracts in `DESIGN.md` §B3. Errors are `{"error": "..."}`.

## iOS app

`ios/project.yml` → `xcodegen generate` → `LiveWire.xcodeproj` (iOS 17+, no
third-party packages). Home map with agency chips and age-faded pins, latest
incident banner, pill player (background audio, lock-screen controls), feed
sheet, incident detail with timeline and Play all, Settings, Alerts. Debug
builds may talk to `http://localhost:8000`; Release has no ATS exception.

## Testing

```bash
bash tests/acceptance.sh                 # full server-side B5 pass from a clean data dir (~2 min)
python tests/test_units.py               # grouping helpers, type vocabulary
python tests/test_push_rules.py          # alert rules, quiet hours, payloads
python tests/check_api.py                # every endpoint, against a running server after a replay
python tests/check_stream.py             # SSE latency + pings, while a replay is running
ANTHROPIC_API_KEY=... python tests/run_samples.py   # extraction on canned transcripts
```

`tests/stub_transcriber.py` and `tests/stub_apns.py` stand in for Groq and
APNs so the whole pipeline runs without keys. iOS unit tests live in
`ios/LiveWireTests` (run from Xcode).

## Tuning

* `lincoln_vocab.txt` is the Whisper prompt. Add streets, businesses and unit
  callsigns you hear mangled — the single biggest lever on transcript quality.
* `cities/lincoln.json` → `extract_hints` holds the street-grid conventions
  fed to Claude; `extract.INCIDENT_TYPES` is the type vocabulary.
* `config.INCIDENT_JOIN_M` (150 m) and `INCIDENT_CLEAR_SEC` (30 min) control
  grouping; `ENERGY_GATE_THRESHOLD` / `ENERGY_HANGOVER_MS` tune the VAD when
  torch isn't installed.
* `GEOCODER=mapbox` fixes intersections and business names that Nominatim
  cannot resolve.

## Costs

VPS €4–6/mo · Broadcastify Premium ~$5/mo · Groq transcription < $2/mo at
~1,500 transmissions/day · Claude Haiku extraction < $1/day.
