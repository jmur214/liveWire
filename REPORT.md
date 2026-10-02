# REPORT — LiveWire build

Everything in `DESIGN.md` §B9 (steps 1–10) is built and committed, one commit
per step, on branch `claude/keen-archimedes-l7vzrp` (this session could not
push to `main`; fast-forward `main` from the branch when you have reviewed).
Read this file first, then `SETUP.md` for what to fill in.

**Headline:** the server side is complete and verified end-to-end against the
replay fixture, a Groq-shaped transcription stub and an APNs stub
(`bash tests/acceptance.sh` → 12/12 PASS, output below). The iOS app is
complete per §A2–A5 and §B4 but **could not be compiled here**: this Linux
container has no Swift toolchain, Xcode or simulator. Every Swift file was
written against the iOS 17 SDK and hand-reviewed twice (once by me, once by a
second review pass) — expect first-build fix-ups of the kind a compiler
catches in minutes, not design gaps.

## Commits (one per build step)

| Step | Commit | What |
|---|---|---|
| 1 | `Add replay dev mode and the lincoln_day fixture` | `main.py --replay/--speed/--loop`, espeak-ng clips, 64-row / 10-incident fixture |
| 2 | `Add incident grouping, city config, bearer auth and the B3 read API` | `cities/lincoln.json`, migrations, `incidents.py`, `/api/*` read endpoints, 401 auth, web map token |
| 3 | `Add /api/stream server-sent events` | SSE with 0.5 s DB polling, 15 s pings, `since_id` catch-up |
| 4 | `Scaffold the iOS app: models, API/SSE clients, AppModel, Home map` | xcodegen project, models, APIClient, StreamClient, AppModel, HomeView |
| 5 | `Add the pill player and AudioEngine` | queue, background audio, Now Playing, cache, resume on launch |
| 6 | `Add the compact incident card, feed sheet and incident detail` | A2.2–A2.4 |
| 7 | `Add Settings: city, server URL/token, appearance, audio, map windows, about` | A2.5, Keychain token |
| 8 | `Add pluggable transcription (Groq/OpenAI/local) and VPS deploy scripts` | B2.1, B2.8, energy-gate tuning, stubs |
| 9 | `Add push alerts: push.py, POST /api/device, PushRegistrar and the Alerts screen` | B2.6, A2.6 |
| 10 | `Finish the acceptance pass: report, setup, acceptance script` | this report, `SETUP.md`, `README.md`, `tests/acceptance.sh` |

## B5 acceptance — server (run against replay mode)

`bash tests/acceptance.sh` (clean temp data dir, API on :8010, APNs + transcription stubs):

```
PASS  POST /api/device stores rules
PASS  /api/stream delivers transmission+incident events <1 s, pings every 15 s (curl -N)
PASS  replay --speed 200 runs to completion with no exceptions
PASS  replay log free of errors/tracebacks
PASS  B3 endpoints: auth 401, health, cities, incidents (8-10, grouping, units, cleared), transmissions, audio, report
PASS  alerts: replayed structure fire/shooting/place produce one push each (3 [1, 6, 10])
PASS  push payload has aps.alert title/body, sound, thread-id, incident_id + APNs headers
PASS  unit tests: grouping helpers, type vocabulary, haversine
PASS  unit tests: push rules, quiet hours, payload
PASS  live pipeline: --source synthetic WAV -> 4 transmissions via Groq-shaped stub
PASS  live pipeline stored 4 transcribed transmissions
PASS  tests/run_samples.py runs (needs ANTHROPIC_API_KEY to pass; exit 1 without it)
```

| B5 item | Result | Evidence |
|---|---|---|
| `--replay … --speed 20` runs to completion, no exceptions; 8–10 incidents; same-address transmissions share one incident; acknowledgements attach via unit names | **PASS (verified)** | Replay exits 0 at 20×, 60× and 200×. `tests/check_api.py`: 10 incidents; the three mapped rows at 1621 N 33rd St form one incident with `tx_count` 9; "Truck 8 responding." has that incident's id; noise rows and a unit of an already-cleared incident stay `incident_id: null`; a medic reused on a later incident joins the most recent active one. |
| `/api/incidents/{id}` shows unit statuses that change across the timeline | **PASS (verified)** | Engine 1 appears as dispatched → "en route" → "clear, available" in the timeline; the incident's `units` map ends at `engine 1: clear, truck 8: on_scene, battalion 1: clear, engine 2: en_route, truck 1: dispatched`; medical incident `engine 5: clear, medic 3: dispatched`. |
| After 30 simulated idle minutes `status` becomes `cleared` | **PASS (verified)** | Clearer scales with `--speed`: at 200× eight incidents were cleared by the end of the fixture; a 60× run captured all ten `cleared` incident events on `/api/stream`. |
| Police clock read → non-default `police_delay_sec` and back-dated `occurred_at` | **PASS (verified)** | `/api/health` reports 863 s (default is 900); every police row's `heard_at − occurred_at` = 863 s after the read (900 s before it). |
| `/api/stream` delivers `transmission` and `incident` events within 1 s; `curl -N` shows pings every 15 s | **PASS (verified)** | `tests/check_stream.py` reads the stream through `curl -N`: 13–21 transmission events per 36 s window, latency min/median/max 0.03/0.10/0.41 s from storage; ping gap 15.1 s; stream refused without the token. |
| Any request without the bearer token → 401 | **PASS (verified)** | `/api/health`, `/api/stream`, `/audio/{file}` → 401 `{"error":"unauthorized"}`; wrong token → 401; `?token=` accepted for the web map's `<audio>` tags; `/` (map page) served without a token. |
| `tests/run_samples.py` passes with `ANTHROPIC_API_KEY` | **NOT VERIFIED — no API key in this environment** | The script runs (exit 1, 2/8 pass without a key because extraction is skipped). Extraction keeps the same output keys; the only changes are the city-neutral prompt template, the type vocabulary and `normalize_type()` (unit-tested). Run it with your key: `ANTHROPIC_API_KEY=… python tests/run_samples.py`. |
| `GROQ_API_KEY` + real WAV → `transcribe()` returns non-empty text | **NOT VERIFIED against Groq — no key; verified against a Groq-shaped stub** | `tests/stub_transcriber.py` validates exactly what `transcribe.py` sends (multipart 16 kHz mono WAV, `model=whisper-large-v3-turbo`, 892-char prompt, `response_format=verbose_json`, `language=en`, bearer header) and returns `verbose_json`; `_collect()` turns segments into text + mean `exp(avg_logprob)`. The live pipeline on `tests/fixtures/audio/synthetic_dispatch.wav` (espeak speech, not radio) produced 4 correctly segmented transmissions. Run with your key: `GROQ_API_KEY=… python -c "import numpy as np, wave, transcribe; w=wave.open('tests/fixtures/audio/<your>.wav'); a=np.frombuffer(w.readframes(w.getnframes()),np.int16).astype(np.float32)/32768; print(transcribe.transcribe(a))"`. |
| *(B7)* Leaflet web map keeps working behind the token | **PASS (verified)** | Loaded `/` in headless Chromium: the page prompts once for the token, then renders 15 pins and 64 feed rows with `?token=` on every `<audio>` URL and no JS errors (`static/index.html`). |
| `deploy/install.sh` on a fresh Ubuntu 24.04 VM → both services active, `https://<host>/api/health` ok | **NOT VERIFIED — no VM / root VPS here** | `bash -n` syntax check passes; units use `EnvironmentFile`, `Restart=always`, a dedicated `livewire` user; Caddyfile reverse-proxies with SSE flushing. The script is idempotent (keeps `.env`). |

## B5 acceptance — iOS

**None of the iOS items could be verified here**: no Swift compiler, Xcode or
simulator exists in this Linux container (`swift`, `swiftc`, `xcodebuild`,
`xcodegen` all absent), so I cannot claim the app compiles or runs. What
exists for each item, and how to verify it once it builds:

| B5 item | Where it is implemented | Verify by |
|---|---|---|
| Cold launch: map on the city, pins within 2 s, no audio | `AppModel.start()/run()` loads `/api/cities` (camera to city centre) then `/api/incidents` + `/api/transmissions` before opening the stream; `AudioEngine` starts idle; resume only if `resumeOnLaunch && wasPlaying` | launch with the replay server |
| Agency chip off → pins disappear and audio skipped | `AppModel.passesFilter`, `visibleIncidents`, `shouldPlay`, `audio.dropQueued` on toggle | tap Police off during replay |
| Banner shows newest mapped incident, updates, tap → Detail | `AppModel.bannerIncident` (newest `first_heard`, traffic ≤ 30 min), `LatestBanner`, `openDetail` | watch the replay; swipe up to dismiss |
| Pins shrink/fade; removed past the remove window | `IncidentPin` (18→12 pt, 1→0.35 opacity over `fadeWindow`, from a 1 s `now` tick), `visibleIncidents` cutoff | set the windows to 15 m / 30 m in Settings |
| Pin tap → card with exactly type, address, distance, time, agency, More details; map pans above the card | `IncidentCard`, `AppModel.select/pan(to:bottomInset:)` | tap a pin |
| Feed half detent; mapped row pans + highlights pin; search; Mapped-only; Now button | `FeedSheet` (`presentationDetents`, `presentationBackgroundInteraction`, frozen snapshot while scrolled away), `AppModel.focus(on:)` | open Feed, scroll, search "engine" |
| Badge counts new transmissions, resets on opening the feed | `FeedStore.unreadCount(since:)`, `showFeed.didSet → markFeedSeen()` (unit-tested in `FeedStoreTests`) | watch the Feed button |
| Play in arrival order; lock phone → continues; lock screen shows transcript; pause from lock screen | `AudioEngine` (`ClipQueue` unit-tested; `.playback/.spokenAudio`, `UIBackgroundModes: audio`, `MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`) | press play, lock the phone |
| Replay a clip while live → live resumes afterwards | `AudioEngine.replay` / `finished()` → `drain()` | tap Play on a feed row |
| Kill while playing; relaunch with Resume on → playing | `Settings.wasPlaying` persisted on start/pause; `AppModel.start()` | swipe-kill, relaunch |
| Detail sections; Play all oldest→newest; Open in Maps with directions | `IncidentDetailView`, `AudioEngine.playAll(timeline.reversed())`, `MKMapItem.openInMaps(launchOptions: directions)` | open any incident |
| Settings → Test shows status; URL change takes effect without relaunch | `SettingsView.test()` → `/api/health`; `RootView.onChange(of: serverURL/apiToken) → reconnect()` | change the URL |
| Alerts: saving rules POSTs `/api/device`; `devices` row matches; replayed structure fire pushes on a sandbox build | `PushRegistrar.sync()` (debounced), `AlertsView.onChange(of: alertRules)`; server side verified with the stub (3 pushes incl. `Structure fire · 2.4 mi`) | turn Alerts on, enable "structure fire", run the replay; real APNs delivery needs your `.p8` on the VPS |
| Light and dark render with the A5 palette | `Theme.swift` dynamic colours, agency colours fixed, `preferredColorScheme` for Always dark | toggle Appearance |
| Phone layouts SE → Pro Max, nothing clipped on SE | overlays use `maxWidth: .infinity`, chips scroll horizontally in Detail, card text truncates; no fixed widths beyond 44–48 pt controls | run on the SE simulator |

Unit tests exist for the parts that don't need a device (`ios/LiveWireTests`:
decoders for every B3 shape, formatting, `FeedStore` merge/badge/banner,
`ClipQueue`, `AudioEngine` pause behaviour) — run them from Xcode once the
project generates.

## Known limitations / things to watch

- **Swift is uncompiled.** The second review pass's findings are folded in (see
  the section below); anything a compiler still flags should be a one-line fix.
- **APNs delivery** is verified only to a stub (payload, headers, 410 handling,
  JWT ES256 signing with a throwaway key). Real delivery needs the `.p8` on
  the VPS and a device.
- **Nominatim intersections** keep the centroid-average approximation from
  §B1; set `GEOCODER=mapbox` for real intersection geocoding.
- The **ingest ↔ API** link is the SQLite file (WAL mode); `/api/stream` polls
  it twice a second. Fine for one user; not a design for many.
- The replay fixture's audio is **espeak-ng speech**; `tests/fixtures/audio/`
  needs a real radio WAV from you for the Groq check.
- Transmissions are pruned after 24 h, incidents and alert records after 7 d.

## Second review pass over the Swift sources

A separate, independent read-through of all 31 Swift files (plus
`project.yml`, both plists and the entitlements) against the iOS 17 SDK /
Swift 5.10 rules found **no construct expected to fail compilation**: API
names and availability, Observation macro usage, `@Bindable`/`Binding`
chains, result-builder rules, every memberwise-initializer call site, Codable
key mapping, actor-isolation of delegate witnesses, module/test-host setup.
It raised five behavioural points; four are fixed in the follow-up commit:

| Finding | Action |
|---|---|
| `allowsBackgroundLocationUpdates` was computed once, before Always authorization was granted, so "Near me now" never got continuous background updates | **Fixed** — `LocationService` remembers the intent and re-applies the flag in `locationManagerDidChangeAuthorization`. |
| With `AVAudioPlayer`, nothing renders between clips, so iOS would suspend the backgrounded app during a quiet spell even while "LIVE · LISTENING" | **Fixed** — a silent 1 s clip loops at volume 0 while the scanner is on and idle; stopped on pause (see DECISIONS.md). |
| Two polling loops (`now` ticker, level meter) would never exit if their owner were deallocated | **Fixed** — `guard let self else { return }`. |
| `convertFromSnakeCase` also rewrites `[String: T]` dictionary keys, so a place name containing `_` would never match its "N alerts this week" count | **Fixed** — per-place stats are now a list of `{name, count}`; unit names can never contain `_`. |
| `MKMapItem(placemark:)` / `item.placemark` are deprecated in the iOS 18 SDK Xcode 16 builds against | **Left as is** — warnings only; the replacements are iOS 18-only and the deployment target is 17.0. |

This is still not a build: compilation against a real toolchain has to happen
in Xcode on your side.

## Your next steps

1. Fill the placeholders listed in `SETUP.md` (Apple Team ID, bundle prefix,
   APNs key + Key ID, stream URL, Groq and Anthropic keys, domain).
2. Deploy: `sudo bash deploy/install.sh scanner.example.com` on an Ubuntu 24.04
   VPS, fill `/opt/livewire/.env`, copy the `.p8`, restart the services, and
   check `https://scanner.example.com/api/health` with the printed token.
3. Open the app: `cd ios && xcodegen generate && open LiveWire.xcodeproj`,
   build the Debug scheme against the replay server first
   (`uvicorn server:app --port 8000` + `python main.py --replay … --speed 10 --loop`,
   token `dev-token`), then point Settings → Server at your VPS and install on
   the phone.
4. Run `ANTHROPIC_API_KEY=… python tests/run_samples.py` and the Groq one-liner
   above to close the two server items that needed your keys; run the iOS unit
   tests and walk the iOS checklist above on the phone.
5. Tune `lincoln_vocab.txt` and `cities/lincoln.json → extract_hints` as you
   hear real traffic; switch to `GEOCODER=mapbox` if intersections miss.

## Every decision (verbatim from `DECISIONS.md`)



- **Replay clock reads use `spoken_time: "heard-840"` and a `{clock}` placeholder in the transcript** — a fixed "23:14" in the fixture would give a different (often >1 h, discarded) delay sample depending on when the replay runs; the relative form yields a deterministic ~14 min sample every run, which is what B5 needs to verify back-dating.
- **`config.CITY_TZ` replaces the `America/Chicago` constant in `delay.py`** — the clock-time maths must follow the city config (B2.3) rather than a hard-coded zone.
- **`main.py` local-file drain loop replaced with a `None` sentinel + `join()`** — B1 names the old sleep loop as a known weak point; the sentinel guarantees the last transmission is stored before exit.
- **Added `.gitignore` and untracked `__pycache__/`** — compiled files were committed in the initial import; CLAUDE.md §7 forbids committing `data/`, `.env`, `.venv/`, keys.
- **Commits go to branch `claude/keen-archimedes-l7vzrp`, not `main`** — CLAUDE.md §3 says to work on `main`, but this session is restricted to its designated branch; one commit per §B9 step is kept, and `main` can be fast-forwarded from the branch when the user reviews.
- **`incidents.updated_at` column added beyond the B2.2 schema** — the API process only sees the database, so `/api/stream` needs a monotonic change marker to emit `incident` events for creates, updates *and* the clearer's status flips without diffing whole rows.
- **`transmissions.location_kind` column added** — B3 returns `location_kind` per incident but B1's schema never stored it; adding a column is allowed ("add only") and avoids re-deriving it from the query string.
- **`meta` key/value table added** — ingest publishes `ingest_heartbeat` and `police_delay_sec` there so `/api/health` (another process) can report `ingest_alive` and the live delay estimate.
- **`API_TOKEN` unset ⇒ `dev-token` with a startup warning** — B5 requires 401 without a token even in dev; a fixed dev value keeps replay/simulator work keyless while `deploy/install.sh` always generates a real token for the VPS.
- **Token also accepted as `?token=` query parameter** — `<audio>` elements in the Leaflet map cannot send headers; the header remains the primary mechanism and the iOS app uses only the header.
- **Incident `first_heard`/`last_heard` use `heard_at`, timeline order uses `occurred_at`** — pin ageing and "Last 11:52 AM" describe when the feed carried it; the Detail view shows the back-dating separately as "Delayed ~14 min".
- **Mapped transmissions group by location regardless of agency** — A4 says "within 150 m of the incident's point" with no agency condition, so a fire medic assisting a sheriff crash joins the same incident; the incident keeps the agency of its first transmission.
- **Incident `address` = geocode query minus the city/state suffix** — e.g. "1621 N 33rd St, Lincoln, NE" → "1621 N 33rd St"; `heard_as` keeps the literal phrase.
- **Incidents and alert records are pruned after 7 days** (transmissions after 24 h as before) — nothing in Part A looks back further than 48 h.
- **Replay scales the 30 min idle rule by `--speed`** — B5 asks for clearing after 30 *simulated* minutes, so at `--speed 20` an incident clears after 90 real seconds.
- **`/api/stream` polls SQLite every 0.5 s rather than receiving pushes from ingest** — ingest and API are separate systemd services (B2.8), so the database is the only shared channel; 0.5 s comfortably meets B5's "within 1 s" and costs two indexed queries per poll per client. `?since_id=` lets a reconnecting client replay transmissions it missed.
- **DEBUG ATS exception is `NSAllowsLocalNetworking` in a separate `Info-Debug.plist`** — xcodegen cannot vary a generated Info.plist per configuration, so Debug and Release point at two hand-written plists; Release carries no `NSAppTransportSecurity` key at all (B2.8).
- **Unknown-agency incidents follow "any chip on"** — A2.1 has chips for police/fire/sheriff only; items the extractor could not attribute stay visible unless every chip is off, so they never become invisible by accident.
- **Banner "newest incident" = greatest `first_heard` among incidents with traffic in the last 30 min** — "slides in on a new incident" reads as creation order; an old incident receiving another transmission does not steal the banner.
- **`Settings` is an `@Observable` class over UserDefaults rather than per-view `@AppStorage`** — AppModel and the audio engine need the same values outside any view; it uses the same `standard` defaults store `@AppStorage` would, and the token goes to the Keychain as B2.8 requires.
- **iOS code is written against iOS 17 APIs but could not be compiled in this environment** (no Swift toolchain on Linux for SwiftUI/MapKit) — see REPORT.md; each file was reviewed by hand for API signatures.
- **Clips play through `AVAudioPlayer` on cached files rather than `AVPlayer` streaming** — every clip is downloaded (the bearer token has to go in a header, which `AVPlayer` URLs cannot carry cleanly) and cached anyway, and `AVAudioPlayer` exposes the metering the 5-bar level meter needs.
- **Now Playing title = summary, else the transcript; artist = "AGENCY · UNIT"; album = transcript** — A3 says "summary or Scanner" while B5 wants the lock screen to show what is being said; acknowledgements have no summary, so the transcript stands in for them.
- **Nothing is queued while the scanner is paused** — resuming would otherwise replay a backlog of stale clips; the pill still shows the latest transcript while paused.
- **The agency chips also filter the feed** — A2.1 says one filter drives pins and audio; a police row in the feed while police pins and audio are off would contradict the user's intent, so the feed follows the same filter.
- **Feed auto-scroll uses a frozen snapshot while scrolled away** — rows that arrive while the user is reading lower down are counted on the "↑ Now" button and merged in when they return to the top, instead of shifting the content under their finger.
- **"Mapped" for a feed row means the transmission itself has coordinates** — acknowledgements attached to an incident by unit name are unmapped rows: Mapped-only hides them and tapping them only highlights, exactly as A2.3 describes.
- **Server URL and token are edited as drafts and applied on Return, "Apply", "Test" or "Done"** — binding the text field straight to Settings would reconnect on every keystroke; applying on commit still "takes effect without relaunch" (B5) through the root view's `onChange` → `reconnect()`.
- **Fade and remove windows are kept consistent (remove ≥ fade)** — a pin cannot fade past the point where it is removed, so moving one slider past the other drags the other along.
- **`GROQ_URL` / `OPENAI_URL` (and model names) are overridable by env** — lets `tests/stub_transcriber.py` stand in for the hosted API so the live pipeline (ffmpeg → VAD → transcribe → store) can be exercised end-to-end without keys; production values are the defaults in B2.1.
- **`tests/fixtures/audio/synthetic_dispatch.wav` is espeak-ng speech, not a radio recording** — B5's Groq check needs a real WAV the user supplies; the synthetic file is only there to drive the VAD/transcription code path.
- **Energy-gate hangover rounds up to whole 32 ms frames (300 ms → 10 frames)** — so the configured hangover is a minimum, never cut short.
- **`install.sh` generates `API_TOKEN` and keeps an existing `.env` on re-run** — the shared secret is a user-supplied value in B6, but a random default is safer than a placeholder reaching production; everything else stays `REPLACE_ME_*` for SETUP.md.
- **uvicorn binds 127.0.0.1 behind Caddy with `--proxy-headers`** — only Caddy's HTTPS listener is public; `/api/stream` is proxied with `flush_interval -1` so SSE bytes are not buffered.
- **`alerts_sent.reason` column added ("type:…", "place:<name>", "near_me")** — the Alerts screen shows "N alerts this week" per saved place, which needs to know which rule fired; `POST /api/device` returns these counts as `stats`.
- **`sandbox` is stored inside the device's rules blob and decides the APNs host per device** — a Debug build registers sandbox tokens while a TestFlight build on the same server needs production APNs; `APNS_SANDBOX` is only the fallback.
- **Alerts are evaluated even when APNs is not configured, but nothing is sent** — `APNS_URL_OVERRIDE` points the client at `tests/stub_apns.py` so the replay → rule → payload path is verifiable here; the real `.p8` delivery can only be checked on the user's VPS with a device.
- **The server deletes a device after APNs answers 410 / BadDeviceToken** — otherwise every new incident would retry a dead token forever.
- **Near-me reports the phone's location at most every 5 min / 250 m from `CLLocationManager` significant-change updates** — enough for a 0.1–2 mi radius with little battery cost; the position is kept only in the device's rules blob.
- **`DATA_DIR` is overridable by env** — `tests/acceptance.sh` runs the whole B5 server pass from a throw-away directory so a developer's `data/` is never touched; production keeps `./data` (`/opt/livewire/data`).
- **`tests/acceptance.sh` is the written B5 checklist for the server** — it starts the API and the two stubs, replays the fixture while reading the stream, and prints PASS/FAIL per item; REPORT.md quotes its output rather than hand-ticked boxes.
- **While the scanner is on and idle, `AudioEngine` loops a silent clip at volume 0** — with `AVAudioPlayer` nothing renders between transmissions, and iOS suspends a backgrounded app whose session is silent, which would stop the SSE feed and queueing after a quiet minute (B5 "lock the phone → audio continues"). The keep-alive stops when the scanner is paused.
- **`POST /api/device` returns per-place alert counts as a list of `{name, count}`, not a dictionary** — the app's snake-case `JSONDecoder` also rewrites dictionary keys, so a place named with an underscore would never match; `normalize_unit` likewise turns `_` into a space so incident `units` keys stay safe.
