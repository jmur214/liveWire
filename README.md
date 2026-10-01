# LiveWire — Lincoln, NE police/fire radio on a live map

Listens to the public safety audio feed, transcribes each transmission, pulls
the location out with an LLM, geocodes it, and plots it on a map with the
transcript and a play button for the original audio.

```
ffmpeg stream ──▶ Silero VAD ──▶ faster-whisper ──▶ Claude (JSON extract) ──▶ geocoder ──▶ SQLite ──▶ Leaflet map
   ingest.py        ingest.py       transcribe.py        extract.py            geocode.py     db.py     server.py + static/
```

## What you need to know about Lincoln specifically

* **The city's official feed is Broadcastify feed #14395** ("Lincoln Police and
  Fire, Lancaster County Sheriff"), linked from lincoln.ne.gov's 911 Center
  page. It mixes three agencies into one stream.
* **LPD audio on it is delayed** by an undisclosed, variable amount (it started
  at 10 min in 2018 and was extended in 2023). All LPD talkgroups are
  encrypted over the air, so an SDR won't help for police. `delay.py` watches
  for dispatchers reading the clock and back-dates police events.
* **Lincoln Fire & Rescue and the Sheriff are live and unencrypted** (P25
  Phase II on the Lancaster County system). You can get them from the same
  stream, or in real time with an RTL-SDR + [trunk-recorder](https://github.com/robotastic/trunk-recorder),
  which gives you per-call clips already tagged by talkgroup — if you go that
  route, point `--source` at trunk-recorder's output instead of a stream.
  Note the system is simulcast; cheap dongles can struggle with it.
* **Getting the stream URL.** Broadcastify only exposes a raw stream URL to
  Premium subscribers, and their terms prohibit automated recording/rebroadcast.
  For a personal project the cleaner path is to email the Lincoln Emergency
  Communications Center and ask for the source stream, since the city owns the
  feed. Put whatever you get in `STREAM_URL`.

## Setup

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt        # torch is big; drop it to use the energy-gate VAD
sudo apt install ffmpeg                # or brew install ffmpeg

export ANTHROPIC_API_KEY=sk-ant-...
export STREAM_URL="https://..."        # see above
# optional, much better geocoding of intersections/businesses:
export GEOCODER=mapbox MAPBOX_TOKEN=pk....
```

Run the two processes:

```bash
python main.py                                   # ingest + transcribe + extract
uvicorn server:app --host 0.0.0.0 --port 8000    # map at http://localhost:8000
```

## Testing without a stream

```bash
python tests/run_samples.py            # extraction + geocoding on canned transcripts
python main.py --source some_recording.mp3   # full pipeline on a local file
```

## Tuning

* `lincoln_vocab.txt` is fed to Whisper as its initial prompt. Add streets,
  businesses, and unit callsigns you hear mangled. This is the single biggest
  lever on transcript quality.
* `WHISPER_MODEL=small.en` runs fine on a CPU in near-real-time. `medium.en` is
  noticeably better on radio audio; use it if you have a GPU (`WHISPER_DEVICE=cuda
  WHISPER_COMPUTE=float16`).
* `extract.py` `SYSTEM` prompt: the Lincoln street-grid conventions live
  here. Adjust `confidence` threshold in `Incident.mappable` if you get too
  many/few pins.
* Nominatim can't geocode intersections; `geocode.py` approximates them by
  averaging the two streets' centroids, which is rough. Mapbox does it properly.

## Costs

Claude Haiku on ~1,500 transmissions/day is well under $1/day. Whisper and
Nominatim are free. A Raspberry Pi 5 or any $5/mo VPS runs the whole thing.

## Things worth adding next

* Group transmissions into incidents (same location within N minutes) so a
  call-out, en-route, and on-scene become one pin with a timeline.
* Push notifications for incident types or neighborhoods you care about.
* Talkgroup tagging if you switch fire to trunk-recorder (gives you agency
  for free instead of inferring it from the transcript).
