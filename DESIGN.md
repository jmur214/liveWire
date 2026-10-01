# Scanner app — build-ready spec (v2)

This document is sufficient for an agent to build the whole system without
further input. Part A is what to build. Part B is how to build it: codebase
state, schemas, API contracts, project setup, dev mode, acceptance criteria,
and build order. Follow the build order in §B.9 exactly.

Working name: `ScannerMap` (user will rename). Platform: iOS 17+, SwiftUI +
MapKit. Server: Python 3.11+, FastAPI, SQLite, hosted on a small Linux VPS.
Single user; no accounts.

---

# Part A — What to build

## A1. Purpose

Open the app when you hear sirens; see what's happening and where within two
seconds. Secondarily, use it as a scanner: listen live with a readable
transcript and a map alongside.

## A2. Screens

### A2.1 Home (root)

Full-screen MapKit map. Follows system light/dark; Settings has an "Always
dark" switch. Map style: `.standard(elevation: .flat, pointsOfInterest:
.excludingAll)`.

Overlays:

- **Agency chips** (top-left): Police, Fire, Sheriff. Tap toggles; off = 45%
  opacity + strikethrough. One filter drives both pins and audio.
- **Settings button** (top-right, 44 pt round).
- **Latest-incident banner** (under chips): newest *mapped* incident that
  passes the agency filter. Agency dot, "`type` · `address`", second line
  "`distance` · `age` · `units`". Tap → Detail. Slides in on a new incident;
  swipe-up dismisses until the next one; hidden if nothing in the last 30 min.
- **Pins**: one per **incident** (§A4). Colour by agency: police `#4F8EF7`,
  fire `#F05D4F`, sheriff `#D8A93C`, unknown `#8A90A3`. Size 18 pt at age 0
  → 12 pt at the fade window (default 1 h); opacity 1.0 → 0.35 over the same
  window; removed at the remove window (default 2 h) measured from `last_heard`.
  An incident with traffic in the last 2 min gets a pulsing ring (agency
  colour at 25%, 1.5 s loop).
- **User location**: `UserAnnotation()`. When-in-use permission.
- **Right rail** (bottom-right, above the pill): locate-me; **Feed** button
  with a badge = transmissions received since the feed was last opened.
- **Pill player** (bottom, 64 pt tall, 16 pt side margins, material blur):
  48 pt play/pause circle; line 1 "`LIVE` · `AGENCY` · `UNIT`" in agency
  colour, 11 pt bold, with a live dot; line 2 current transcript, 14 pt, one
  line, ellipsis; 5-bar level meter driven by the player's audio level.
  Paused: line 1 "SCANNER PAUSED" muted, line 2 last transcript, no meter.
  Tapping the text area opens the feed sheet.

### A2.2 Pin tap → compact card

Bottom card (22 pt radius, panel colour, hairline border). Map pans so the
pin is centred in the visible area above the card; the pin enlarges to 26 pt.

- Row 1: agency dot · **incident type** (18 pt bold) · close button
- Row 2: address (14 pt)
- Row 3: chips — distance ("0.6 mi", bold), time ("11:52 AM · 2 min ago"),
  agency
- Row 4: **More details** (48 pt, full width) → Detail

Close, swipe-down, or tapping the map dismisses. Nothing else on the card.

### A2.3 Feed (sheet)

Presented with `.presentationDetents([.fraction(0.5), .large])`, opens at
half. `.presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.5)))`
so the map stays usable at half.

- Header: "Feed" · LIVE dot · "N in last hour".
- Rows, newest first: agency dot; "11:52 AM · 2m ago" + pin glyph if mapped;
  one-line summary (15 pt semibold, mapped rows only); transcript (13 pt
  muted); play button (32 pt).
- **Tap a mapped row**: sheet goes to half, map pans to the incident's pin,
  pin enlarges, row highlights (agency colour at 12%). Unmapped rows: no map
  action; the row still highlights for 0.5 s.
- **Full detent only** (hidden at half): search field (matches transcript,
  summary, address, units); **Mapped only** toggle; **↑ Now** button, visible
  when scrolled >1 row from the top, labelled with the count of new rows.
- Auto-scroll: when at the top, new rows insert with animation; when
  scrolled down, they accumulate.
- Opening the feed zeroes the badge.

### A2.4 Detail (pushed, full screen)

Nav bar: back; title "Incident"; share (summary, address, Apple Maps URL).

1. **Header**: "`AGENCY` · `ACTIVE|CLEARED` · `N` TRANSMISSIONS" (11 pt
   bold, agency colour); type (26 pt, weight 800); address (16 pt); chips:
   distance, "First 11:51 AM", "Last 11:52 AM".
2. **Mini map** (190 pt, 18 pt radius): incident pin, user dot if within the
   frame, **Open in Maps** button → `MKMapItem.openInMaps` with directions.
3. **Units**: chips "`Engine 1` en route" — status from §A4.
4. **Details grid** (2 cols): Agency (full name); Feed timing ("Live" or
   "Delayed ~14 min"); Heard as (literal location phrase); Location
   confidence (High/Medium/Low from `extract_confidence` ≥.8/≥.6/else, plus
   location kind).
5. **Timeline**: all transmissions, newest at top, each: time, unit (first
   unit mentioned, else "Dispatch"), transcript, Play. **Play all** plays
   oldest → newest.
6. **Report wrong location** → `POST /api/report`, button becomes "Reported".

### A2.5 Settings

Sections: City (picker from `/api/cities`); Server (URL text field, "Test"
button that hits `/api/health`); Appearance (System / Always dark); Audio
(Dispatch only; Resume on launch); Map (fade window 15 m–2 h; remove window
30 m–6 h); Alerts (own screen, §A2.6); About (version, server version).

### A2.6 Alerts

- Master switch.
- **Incident types, anywhere in city**: checklist of the server's type
  vocabulary (§B2.4).
- **Near saved places, any type**: Home, Work, + add (name + address via
  `MKLocalSearch` + radius 0.1–2 mi). Each row: on/off, radius, "N alerts
  this week".
- **Near me now**: off by default; radius; enabling requests Always
  location and explains the battery cost.
- **Quiet hours**: start/end; allow-list of types that still get through.

Rules are stored on the server (§B3 `/api/device`) and evaluated there.

## A3. Audio behaviour

- **Live scanner**: a queue of transmission clips. Each new transmission
  that passes the agency filter (and, if Dispatch-only is on, has a
  `summary`) is appended; the player drains the queue in order. If the queue
  exceeds 10, drop the oldest and show "skipped N" briefly in the pill.
- `AVAudioSession` category `.playback`, mode `.spokenAudio`; Background
  Modes → Audio. Now Playing info: title = summary or "Scanner", artist =
  "`AGENCY` · `UNIT`", so the lock screen shows what's being said. Remote
  command centre: play/pause.
- **Replay**: any Play button plays that clip immediately; live playback
  pauses and resumes after.
- **No autoplay** on cold launch. The playing state is persisted; with
  "Resume on launch" on, the app resumes if it was playing when backgrounded
  or killed.
- Clips are WAV from `/audio/{file}`; the app caches the last 200 in
  `Caches/`.

## A4. Incidents (server-side grouping)

- A **mapped** transmission joins an existing *active* incident if its point
  is within 150 m of the incident's point; otherwise it creates one.
- An **unmapped** transmission joins the most recent active incident that
  shares any unit callsign with it (exact string match on normalised units,
  e.g. "engine 1"); otherwise it stays ungrouped (`incident_id NULL`) and
  appears only in the feed.
- Incident point = the first mapped transmission's point (never averaged).
- `status`: `active` until 30 min with no transmissions, then `cleared`
  (a background task runs each minute).
- Unit status, per unit per incident, from the latest transcript that names
  it, in this order of checks: contains "clear"/"available"/"back in service"
  → `clear`; contains "on scene"/"arrived"/"ten-ninety-seven"/"10-97" →
  `on_scene`; contains "en route"/"responding"/"ten-seventy-six"/"10-76" →
  `en_route`; else `dispatched`.
- Police `occurred_at` is back-dated by the running delay estimate
  (`delay.py`); fire and sheriff are not.

## A5. Visual language

- SF Pro (system). Weights: 800 incident titles, 700 headers, 600 chips, 400
  body. Sizes as given per screen.
- Dark: ground `#0F1115`, panel `#171A21`, text `#E6E8EE`, muted `#9AA1B4`,
  hairline `rgba(255,255,255,0.14)`. Light: ground `#EEF0F3`, panel
  `#FFFFFF`, text `#14171C`, muted `#5B6270`, hairline `rgba(0,0,0,0.08)`.
- Agency colours identical in both modes.
- Radii: cards 22, pill 32, chips 17, buttons 14, grid cells 12.
- Floating surfaces: `.ultraThinMaterial` + hairline border + shadow
  (0, 8, 30, 0.45 dark / 0.15 light).
- Touch targets ≥ 44 pt. Icons: SF Symbols only.

## A6. Out of scope for v1

Auto-detect city, Live Activity / Dynamic Island, widget, Android, any
sharing of audio to other people.

---

# Part B — How to build it

## B1. State of the codebase (read before touching anything)

Repo layout as it exists now:

```
config.py          env-driven settings; LINCOLN_BBOX, MAP_CENTER, paths
ingest.py          ffmpeg → PCM → Silero VAD → yields (heard_at, float32 audio)
transcribe.py      faster-whisper, local CPU, primed with lincoln_vocab.txt
extract.py         Claude → Incident dataclass {agency, incident_type,
                   location_text, geocode_query, location_kind, units,
                   spoken_time, summary, confidence}; .mappable property
geocode.py         Nominatim (default) or Mapbox, bbox-restricted, sqlite cache
delay.py           DelayEstimator: median police delay from spoken clock times
db.py              sqlite: table `transmissions`; insert(), recent(), prune()
main.py            orchestrator: ingest → queue → worker(transcribe → extract
                   → geocode → db.insert + save WAV clip to data/audio/)
server.py          FastAPI: GET /api/events, GET /api/transcript, /audio/*,
                   static/index.html (a Leaflet web map — keep it working)
lincoln_vocab.txt  Whisper initial prompt (streets, units, phrases)
tests/             sample_transcripts.json + run_samples.py (extraction test)
```

Existing `transmissions` schema (do not rename columns; add only):

```sql
CREATE TABLE transmissions (
  id INTEGER PRIMARY KEY, heard_at REAL NOT NULL, occurred_at REAL NOT NULL,
  duration REAL, transcript TEXT, asr_confidence REAL, audio_file TEXT,
  agency TEXT, incident_type TEXT, location_text TEXT, geocode_query TEXT,
  units TEXT /* JSON list */, summary TEXT, extract_confidence REAL,
  lat REAL, lon REAL
);
```

Audio clips are 16 kHz mono 16-bit WAV in `data/audio/<ms>.wav`, pruned
after `KEEP_AUDIO_HOURS` (24).

Known weak points to fix as part of this build: `main.py` ends with a crude
drain loop for local files; `geocode.py` intersection handling for Nominatim
is a centroid-average hack (acceptable; Mapbox is the real fix).

## B2. Server changes

### B2.1 Transcription becomes pluggable

`config.TRANSCRIBER` = `local` | `groq` | `openai` (default `groq`).
`transcribe.transcribe(audio) -> (text, confidence)` keeps its signature.

- `groq`: POST `https://api.groq.com/openai/v1/audio/transcriptions`, model
  `whisper-large-v3-turbo`, `prompt` = vocab file contents (truncate to 224
  tokens ≈ 900 chars), `response_format=verbose_json`, `language=en`. Send
  the clip as an in-memory WAV. Confidence = mean of `exp(avg_logprob)` over
  segments. Env: `GROQ_API_KEY`.
- `openai`: same request shape against `https://api.openai.com/v1/audio/transcriptions`,
  model `whisper-1`. Env: `OPENAI_API_KEY`.
- `local`: existing faster-whisper path.

### B2.2 Schema additions

```sql
CREATE TABLE incidents (
  id INTEGER PRIMARY KEY,
  city TEXT NOT NULL,
  agency TEXT, incident_type TEXT, summary TEXT, address TEXT,
  lat REAL NOT NULL, lon REAL NOT NULL,
  first_heard REAL NOT NULL, last_heard REAL NOT NULL,
  status TEXT NOT NULL DEFAULT 'active',      -- active | cleared
  units TEXT NOT NULL DEFAULT '{}',           -- JSON {"engine 1":"en_route",...}
  tx_count INTEGER NOT NULL DEFAULT 0,
  reported_wrong INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX ix_inc_last ON incidents(last_heard);
ALTER TABLE transmissions ADD COLUMN incident_id INTEGER REFERENCES incidents(id);
ALTER TABLE transmissions ADD COLUMN city TEXT NOT NULL DEFAULT 'lincoln';
CREATE INDEX ix_tx_inc ON transmissions(incident_id);

CREATE TABLE devices (
  token TEXT PRIMARY KEY,                     -- APNs hex token
  city TEXT NOT NULL,
  rules TEXT NOT NULL,                        -- JSON, shape in B3 /api/device
  updated_at REAL NOT NULL
);
CREATE TABLE alerts_sent (
  id INTEGER PRIMARY KEY, token TEXT, incident_id INTEGER, sent_at REAL
);
```

Migrations: `db.init()` runs `CREATE TABLE IF NOT EXISTS` for new tables and
wraps each `ALTER TABLE` in try/except for `duplicate column`.

### B2.3 City config

`cities/lincoln.json` (one file per city; `config.CITY` selects, default
`lincoln`):

```json
{
  "id": "lincoln", "name": "Lincoln, NE", "tz": "America/Chicago",
  "center": [40.8136, -96.7026],
  "bbox": [-96.85, 40.65, -96.50, 40.95],
  "stream_url_env": "STREAM_URL",
  "vocab_file": "lincoln_vocab.txt",
  "agencies": {
    "police":  {"name": "Lincoln Police Department", "delayed": true},
    "fire":    {"name": "Lincoln Fire & Rescue", "delayed": false},
    "sheriff": {"name": "Lancaster County Sheriff", "delayed": false}
  },
  "extract_hints": "Lettered streets run E–W (A–Y, O St main); numbered streets N–S; ..."
}
```

`config.py` loads it; `LINCOLN_BBOX`/`MAP_CENTER` become `city.bbox`/`city.center`;
`extract.SYSTEM` is built from a city-neutral template + `extract_hints`.

### B2.4 Incident type vocabulary

`extract.py` constrains `incident_type` to this list (anything else → closest
or `other`): `structure fire, vehicle fire, grass fire, fire alarm, gas leak,
medical, injury accident, non-injury accident, hit and run, traffic stop,
disturbance, domestic, assault, shooting, stabbing, robbery, burglary, theft,
shoplifting, suspicious person, suspicious vehicle, welfare check, trespass,
pursuit, missing person, overdose, water rescue, hazmat, other`.
`GET /api/cities` returns it so the Alerts screen can list it.

### B2.5 Grouping (`incidents.py`, called from `main.process` after `db.insert`)

Implement §A4 exactly. Return the `incident_id`; update `transmissions.incident_id`,
the incident's `last_heard`, `tx_count`, `units` JSON (unit → status), and
`summary`/`incident_type` if the incident's are NULL and the new transmission
has them. A background thread marks `active` → `cleared` at 30 min idle.

### B2.6 Alerts (`push.py`)

- APNs HTTP/2 with token auth: `httpx.Client(http2=True)`, JWT ES256 signed
  with the `.p8` key, cached 50 min. Env: `APNS_KEY_PATH`, `APNS_KEY_ID`,
  `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `APNS_SANDBOX` (true for dev builds).
- Evaluate on **incident creation** only (not on every transmission), for
  every device in `devices` with the same city:
  1. master off → skip. 2. quiet hours active and type not in allow-list →
  skip. 3. match if type ∈ `types`, or distance(incident, place) ≤ place
  radius for any enabled place, or (`near_me.enabled` and the device's last
  reported location is within `near_me.radius_mi` and ≤ 10 min old).
  4. one push per (token, incident); record in `alerts_sent`.
- Payload: `{"aps":{"alert":{"title":"Structure fire · 0.6 mi","body":"1621 N 33rd St — Truck 8, Battalion 1"},"sound":"default","thread-id":"<city>"},"incident_id":123}`.
- The app reports its location for near-me via `POST /api/device` (§B3)
  from a background location update; the server stores `last_lat/lon/at`
  in the device's `rules` blob.

### B2.7 Dev / replay mode (build this FIRST — the app is developed against it)

`python main.py --replay tests/fixtures/lincoln_day.json [--speed 10] [--loop]`

- The fixture is a list of transmissions with pre-extracted fields, so no
  API keys are required:
  ```json
  [{"offset_sec": 0, "agency": "fire", "transcript": "Truck 8, Battalion 1, structure fire, 1621 North 33rd Street, smoke showing second floor.",
    "incident_type": "structure fire", "summary": "Structure fire, smoke showing", "location_text": "1621 North 33rd",
    "geocode_query": "1621 N 33rd St, Lincoln, NE", "location_kind": "address", "lat": 40.8268, "lon": -96.6900,
    "units": ["Truck 8", "Battalion 1"], "confidence": 0.9, "spoken_time": null}, ...]
  ```
- Replay emits each row at `offset_sec / speed`, synthesises a WAV clip
  (`espeak-ng` if installed, else a 0.8 s 440 Hz tone with the duration
  scaled to word count) so the audio pipeline is exercised, skips
  transcription/extraction/geocoding, and runs grouping, delay back-dating
  and alerts as in production. `--loop` restarts with a fresh time base.
- Write `tests/fixtures/lincoln_day.json` with ~60 transmissions over a
  simulated 90 minutes: 8–10 incidents (mix of agencies, two at the same
  address to exercise grouping, three unmapped acknowledgements per incident,
  one police transmission that reads a clock time), coordinates inside
  Lincoln's bbox.

### B2.8 Deployment (VPS)

Target: Ubuntu 24.04, 1–2 vCPU, 2 GB RAM (Hetzner CX22 or equivalent).
Provide `deploy/`:

- `install.sh`: apt `ffmpeg python3-venv caddy espeak-ng`; create
  `/opt/scannermap`; venv; `pip install -r requirements.txt` (drop `torch`
  and `faster-whisper` from the default requirements; move them to
  `requirements-local-whisper.txt`; Silero VAD without torch is not possible,
  so ingest's energy-gate fallback becomes the default on the VPS, tuned:
  threshold 0.015, and add a 300 ms hangover).
- `scannermap-ingest.service` and `scannermap-api.service` (systemd, `Restart=always`,
  `EnvironmentFile=/opt/scannermap/.env`).
- `Caddyfile`: `scanner.example.com { reverse_proxy 127.0.0.1:8000 }` —
  Caddy obtains the TLS cert. iOS ATS requires HTTPS; do not add an ATS
  exception.
- `.env.example` listing every variable in this document.
- API auth: single shared secret. `config.API_TOKEN`; every `/api/*` and
  `/audio/*` request must carry `Authorization: Bearer <token>` or get 401.
  The app stores it in Keychain; Settings has a field for it.

## B3. API contracts

All responses JSON; times are Unix seconds (float); all endpoints require the
bearer token. Errors: `{"error": "message"}` with a 4xx/5xx status.

```
GET /api/health
→ {"ok": true, "version": "1.0.0", "city": "lincoln", "ingest_alive": true,
   "police_delay_sec": 873, "last_transmission_at": 1790831991.1}

GET /api/cities
→ {"cities": [{"id":"lincoln","name":"Lincoln, NE","center":[40.8136,-96.7026],
   "agencies":{"police":{"name":"Lincoln Police Department","delayed":true}, ...},
   "incident_types":["structure fire", ...]}]}

GET /api/incidents?hours=2&agencies=police,fire
→ {"incidents": [{
   "id": 123, "agency": "fire", "incident_type": "structure fire",
   "summary": "Structure fire, smoke showing", "address": "1621 N 33rd St",
   "lat": 40.8268, "lon": -96.69, "first_heard": 1790831900.0,
   "last_heard": 1790831991.1, "status": "active", "tx_count": 3,
   "units": {"truck 8": "on_scene", "battalion 1": "on_scene", "engine 1": "en_route"},
   "delayed": false, "delay_sec": 0, "location_kind": "address",
   "location_confidence": 0.9, "heard_as": "1621 North 33rd"}]}
   (sorted last_heard desc; `delayed`/`delay_sec` from the city config and
   the delay estimator for police)

GET /api/incidents/{id}
→ the incident object above plus
   "transmissions": [{"id": 9001, "occurred_at": ..., "heard_at": ...,
     "transcript": "...", "audio_file": "1790831991108.wav", "duration": 6.1,
     "units": ["Truck 8"], "summary": null}, ...]  (occurred_at desc)

GET /api/transmissions?since_id=9000&limit=200
→ {"transmissions": [{"id": 9001, "incident_id": 123, "agency": "fire",
   "occurred_at": ..., "heard_at": ..., "transcript": "...", "summary": "...",
   "address": "1621 N 33rd St", "lat": 40.8268, "lon": -96.69,
   "audio_file": "1790831991108.wav", "duration": 6.1, "units": ["Truck 8"]}],
   "latest_id": 9001}
   (id asc so the client can page; without since_id: last `limit` rows)

GET /api/stream            (text/event-stream)
   event: transmission  data: <one transmissions row as above>
   event: incident      data: <one incident object>        (on create/update)
   event: ping          data: {}                            (every 15 s)
   The client falls back to polling /api/transmissions every 5 s if the
   stream drops.

GET /audio/{file}          → audio/wav

POST /api/device
   {"token": "<apns hex>", "city": "lincoln", "sandbox": true,
    "rules": {"enabled": true, "types": ["structure fire","shooting"],
      "places": [{"name":"Home","lat":40.81,"lon":-96.70,"radius_mi":0.5,"enabled":true}],
      "near_me": {"enabled": false, "radius_mi": 0.5},
      "quiet": {"enabled": true, "start": "23:00", "end": "07:00", "allow": ["structure fire","shooting"]},
      "last_location": {"lat": 40.81, "lon": -96.70, "at": 1790831991.1}}}
→ {"ok": true}

POST /api/report           {"incident_id": 123, "reason": "wrong_location"}
→ {"ok": true}
```

## B4. iOS project

- Xcode 16+, iOS 17.0 deployment target, Swift 5.10, SwiftUI lifecycle.
- Bundle ID `com.<user>.scannermap` (placeholder; the user sets it). Team:
  the user's. Create the project with `xcodegen` from a `project.yml` in
  `ios/` so the project file is reproducible; commit `project.yml`, not the
  `.xcodeproj`.
- Capabilities: Background Modes (Audio, AirPlay and PiP; Location updates),
  Push Notifications.
- `Info.plist` strings: `NSLocationWhenInUseUsageDescription` ("Shows
  incidents near you and their distance"), `NSLocationAlwaysAndWhenInUseUsageDescription`
  ("Needed only for 'Near me now' alerts"), `UIBackgroundModes` = `audio`,
  `location`.
- No third-party packages. MapKit (SwiftUI `Map`, iOS 17 API),
  AVFoundation, CoreLocation, UserNotifications, MediaPlayer (Now Playing).

File layout:

```
ios/project.yml
ios/ScannerMap/App/ScannerMapApp.swift          @main; AppDelegate for APNs token
ios/ScannerMap/App/AppModel.swift               @Observable root state: incidents, transmissions,
                                                filters, settings, unread count, selection
ios/ScannerMap/Services/APIClient.swift         async/await; bearer token; decoders for B3
ios/ScannerMap/Services/StreamClient.swift      SSE reader with polling fallback
ios/ScannerMap/Services/AudioEngine.swift       queue + AVPlayer; session config; Now Playing; cache
ios/ScannerMap/Services/LocationService.swift   CLLocationManager wrapper; distance helpers
ios/ScannerMap/Services/PushRegistrar.swift     permission, token, POST /api/device
ios/ScannerMap/Services/Settings.swift          @AppStorage-backed; Keychain for API token
ios/ScannerMap/Models/*.swift                   Incident, Transmission, City, AlertRules (Codable)
ios/ScannerMap/Views/HomeView.swift             map + overlays
ios/ScannerMap/Views/Components/AgencyChips.swift, LatestBanner.swift, PillPlayer.swift,
                                                IncidentPin.swift, RightRail.swift
ios/ScannerMap/Views/IncidentCard.swift         compact card
ios/ScannerMap/Views/FeedSheet.swift
ios/ScannerMap/Views/IncidentDetailView.swift
ios/ScannerMap/Views/SettingsView.swift, AlertsView.swift, PlaceEditor.swift
ios/ScannerMap/Theme/Theme.swift                colours, radii, agency palette
ios/ScannerMap/Preview/Fixtures.swift           sample Incident/Transmission for previews
ios/ScannerMapTests/                            grouping-free unit tests: decoders, distance,
                                                feed merge logic, queue behaviour
```

Behavioural notes:

- `AppModel` merges SSE events into arrays keyed by id; incidents list is
  re-sorted by `last_heard`; pins derive from incidents filtered by agency
  and remove window.
- Pin age effects are computed in the view from `last_heard` and a 1 s timer.
- Distance uses `CLLocation.distance(from:)`; shown as "0.6 mi" (<10 mi,
  one decimal) or "12 mi"; "—" when location is unavailable.
- The badge is `transmissions.filter { $0.id > lastSeenTransmissionId }.count`.
- Settings "Test" calls `/api/health` and shows ingest status and the
  police delay.

## B5. Acceptance criteria

Server (run against replay mode unless stated):

- [ ] `python main.py --replay tests/fixtures/lincoln_day.json --speed 20`
      runs to completion with no exceptions; `/api/incidents` returns 8–10
      incidents; the two same-address transmissions share one incident;
      acknowledgements attach to incidents via unit names.
- [ ] `/api/incidents/{id}` shows unit statuses that change across the timeline.
- [ ] After 30 simulated idle minutes an incident's `status` becomes `cleared`.
- [ ] The police transmission with a spoken time produces a non-default
      `police_delay_sec` in `/api/health` and a back-dated `occurred_at`.
- [ ] `/api/stream` delivers `transmission` and `incident` events within 1 s
      of replay emitting them; `curl -N` shows pings every 15 s.
- [ ] Any request without the bearer token → 401.
- [ ] `tests/run_samples.py` still passes with `ANTHROPIC_API_KEY` set.
- [ ] With `GROQ_API_KEY` set and a real WAV in `tests/fixtures/audio/`,
      `transcribe.transcribe()` returns non-empty text.
- [ ] `deploy/install.sh` on a fresh Ubuntu 24.04 VM results in both services
      active and `https://<host>/api/health` returning `ok: true`.

iOS (against the replay server over HTTPS or the simulator with
`http://localhost:8000` via a DEBUG-only ATS exception):

- [ ] Cold launch: map centred on the city, pins present within 2 s, no
      audio playing.
- [ ] Agency chip off → its pins disappear and its audio is skipped.
- [ ] Banner shows the newest mapped incident, updates on a new one, tap →
      Detail.
- [ ] Pins visibly shrink/fade with age; an incident older than the remove
      window is gone.
- [ ] Tap pin → card with exactly type, address, distance, time, agency,
      More details; map pans so the pin is above the card.
- [ ] Feed opens at half; tapping a mapped row pans the map and highlights
      the pin; at full detent search filters rows; Mapped-only hides
      acknowledgements; Now button appears when scrolled and returns to top.
- [ ] Badge counts new transmissions and resets on opening the feed.
- [ ] Play: transmissions play in arrival order; lock the phone → audio
      continues; lock screen shows the transcript; pause from lock screen
      works.
- [ ] Replay a clip from a row while live is playing → clip plays, live
      resumes afterwards.
- [ ] Kill the app while playing; relaunch with Resume on → playing.
- [ ] Detail shows all sections in A2.4; Play all plays oldest → newest;
      Open in Maps launches Apple Maps with directions.
- [ ] Settings → Test shows server status; changing the server URL takes
      effect without relaunch.
- [ ] Alerts: saving rules POSTs to `/api/device`; the server's `devices`
      row matches; a replayed structure fire with "structure fire" enabled
      produces a push on a sandbox build.
- [ ] Light and dark both render with the A5 palette; no unreadable text.
- [ ] Phone-size layouts only (iPhone SE 3 through Pro Max); nothing
      clipped on SE.

## B6. What the user supplies (not the agent)

- Apple: Team ID, bundle ID, an APNs auth key (.p8) + key ID, running
  Xcode, installing to the phone (TestFlight or direct).
- Broadcastify Premium stream URL → `STREAM_URL`.
- API keys: `GROQ_API_KEY` (or `OPENAI_API_KEY`), `ANTHROPIC_API_KEY`,
  optionally `MAPBOX_TOKEN`.
- A VPS with a domain pointed at it.
- A shared `API_TOKEN` string.

## B7. Non-goals and guardrails for the agent

- Do not add accounts, analytics, or third-party SDKs.
- Do not change the extraction prompt's output keys.
- Keep the Leaflet web map working (it is the server's smoke test).
- Audio clips are never exposed without the bearer token.
- Do not commit `.env`, keys, or `data/`.

## B8. Costs (for the user's reference)

VPS €4–6/mo · Broadcastify Premium ~$5/mo · Groq transcription < $2/mo at
~1,500 transmissions/day · Claude Haiku extraction < $1/day · Apple
Developer (already held).

## B9. Build order

1. Dev/replay mode + fixture (B2.7). Everything else is tested against it.
2. Schema additions, city config, incident grouping, `/api/incidents`,
   `/api/transmissions`, bearer auth, `/api/health`, `/api/cities`.
3. `/api/stream` (SSE).
4. iOS project scaffold via xcodegen; models; `APIClient`; `StreamClient`;
   `AppModel` with the DEBUG ATS exception; HomeView with pins and chips.
5. Pill player + `AudioEngine` (background audio, Now Playing).
6. Incident card; Feed sheet; Detail view.
7. Settings; server URL/token; appearance.
8. Pluggable transcription (Groq); VPS deploy scripts; verify end-to-end on
   a real stream.
9. Push: `push.py`, `/api/device`, `PushRegistrar`, Alerts screen.
10. Acceptance pass (B5) with a written checklist of results.
