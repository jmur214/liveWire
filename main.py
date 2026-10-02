"""Pipeline orchestrator: stream -> VAD -> whisper -> extract -> geocode -> sqlite.

Run alongside server.py (the API + map). Usage:
    STREAM_URL=https://... ANTHROPIC_API_KEY=... python main.py
    python main.py --source tests/sample.mp3                      # full pipeline on a local recording
    python main.py --replay tests/fixtures/lincoln_day.json --speed 10 [--loop]
                                                                  # dev mode: no API keys needed
"""
from __future__ import annotations

import argparse
import io
import json
import logging
import queue
import re
import shutil
import subprocess
import threading
import time
import wave
from datetime import datetime
from pathlib import Path

import numpy as np

import config
import db
import incidents
from delay import DelayEstimator
from extract import Incident, extract
from geocode import geocode
from ingest import transmissions
from transcribe import transcribe

log = logging.getLogger("livewire")


def _save_clip(audio: np.ndarray, heard_at: float) -> str:
    name = f"{int(heard_at * 1000)}.wav"
    path = config.AUDIO_DIR / name
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(config.SAMPLE_RATE)
        w.writeframes((np.clip(audio, -1, 1) * 32767).astype(np.int16).tobytes())
    return name


def _prune_audio() -> None:
    cutoff = time.time() - config.KEEP_AUDIO_HOURS * 3600
    for p in config.AUDIO_DIR.glob("*.wav"):
        if p.stat().st_mtime < cutoff:
            p.unlink(missing_ok=True)


def store(
    heard_at: float,
    audio: np.ndarray,
    text: str,
    asr_conf: float,
    inc: Incident,
    lat: float | None,
    lon: float | None,
    delays: DelayEstimator,
) -> int:
    """Everything after transcription/extraction/geocoding: delay estimate, clip,
    DB row, incident grouping (and alerts on a new incident). Shared by the live
    pipeline and replay mode. Returns the transmission row id."""
    if inc.agency == "police" or inc.spoken_time:
        delays.observe(text, heard_at, inc.spoken_time)
    duration = len(audio) / config.SAMPLE_RATE
    row = {
        "heard_at": heard_at,
        "occurred_at": delays.actual_time(heard_at, inc.agency),
        "duration": duration,
        "transcript": text,
        "asr_confidence": asr_conf,
        "audio_file": _save_clip(audio, heard_at),
        "agency": inc.agency,
        "incident_type": inc.incident_type,
        "location_text": inc.location_text,
        "geocode_query": inc.geocode_query,
        "location_kind": inc.location_kind,
        "units": inc.units,
        "summary": inc.summary,
        "extract_confidence": inc.confidence,
        "lat": lat,
        "lon": lon,
        "city": config.CITY_ID,
    }
    row["id"] = tx_id = db.insert(row)
    incidents.assign(row)
    db.set_meta("police_delay_sec", f"{delays.police_delay:.0f}")
    return tx_id


def process(heard_at: float, audio: np.ndarray, delays: DelayEstimator) -> int | None:
    """Live path: transcribe -> extract -> geocode -> store."""
    duration = len(audio) / config.SAMPLE_RATE
    text, asr_conf = transcribe(audio)
    if not text:
        return None
    log.info("[%4.1fs] %s", duration, text)

    inc = extract(text)
    lat = lon = None
    if inc.mappable:
        pt = geocode(inc.geocode_query, inc.location_kind)
        if pt:
            lat, lon = pt
            log.info("   -> %s @ %.4f,%.4f", inc.geocode_query, lat, lon)
        else:
            log.info("   -> could not geocode %r", inc.geocode_query)
    return store(heard_at, audio, text, asr_conf, inc, lat, lon, delays)


# --- Replay / dev mode ---------------------------------------------------------------------

def _synth_clip(text: str) -> np.ndarray:
    """Make a clip for a replayed transmission so the audio path is exercised.
    Uses espeak-ng when installed; otherwise a 440 Hz tone whose length scales
    with the word count (0.8 s minimum)."""
    if shutil.which("espeak-ng"):
        try:
            out = subprocess.run(
                ["espeak-ng", "--stdout", "-v", "en-us", "-s", "175", text],
                capture_output=True, timeout=30, check=True,
            ).stdout
            # espeak's streamed header carries a bogus length; read the data chunk directly.
            with wave.open(io.BytesIO(out)) as w:
                rate, width, ch = w.getframerate(), w.getsampwidth(), w.getnchannels()
            i = out.find(b"data")
            pcm = np.frombuffer(out[i + 8:], dtype=np.int16 if width == 2 else np.uint8)
            if ch > 1:
                pcm = pcm.reshape(-1, ch).mean(axis=1)
            audio = pcm.astype(np.float32) / (32768.0 if width == 2 else 128.0)
            if rate != config.SAMPLE_RATE:
                n = int(len(audio) * config.SAMPLE_RATE / rate)
                audio = np.interp(
                    np.linspace(0, len(audio) - 1, n), np.arange(len(audio)), audio
                ).astype(np.float32)
            return audio
        except Exception as e:  # pragma: no cover - depends on the host
            log.warning("espeak-ng failed (%s); using a tone", e)
    words = max(1, len(text.split()))
    dur = max(0.8, 0.3 * words)
    t = np.arange(int(dur * config.SAMPLE_RATE)) / config.SAMPLE_RATE
    return (0.3 * np.sin(2 * np.pi * 440 * t)).astype(np.float32)


_HEARD_REL = re.compile(r"^heard([+-]\d+)$")


def _replay_row(row: dict, heard_at: float, delays: DelayEstimator) -> int:
    """Store one pre-extracted fixture row as if it had just come off the air."""
    text = row["transcript"]
    spoken = row.get("spoken_time")
    m = _HEARD_REL.match(spoken or "")
    if m:
        # "heard-840": the dispatcher read a clock 840 s before we heard it, so the
        # delay estimator gets a deterministic sample whenever the replay runs.
        spoken = datetime.fromtimestamp(heard_at + int(m.group(1)), config.CITY_TZ).strftime("%H:%M")
    if "{clock}" in text:
        text = text.replace("{clock}", spoken or "")
    inc = Incident(
        agency=row.get("agency") or "unknown",
        incident_type=row.get("incident_type"),
        location_text=row.get("location_text"),
        geocode_query=row.get("geocode_query"),
        location_kind=row.get("location_kind"),
        units=list(row.get("units") or []),
        spoken_time=spoken,
        summary=row.get("summary"),
        confidence=float(row.get("confidence") or 0.0),
    )
    audio = _synth_clip(text)
    lat, lon = row.get("lat"), row.get("lon")
    if lat is None or lon is None:
        lat = lon = None
    tx_id = store(heard_at, audio, text, 0.95, inc, lat, lon, delays)
    log.info("[replay %5.0fs] #%d %-7s %s%s", row["offset_sec"], tx_id, inc.agency,
             "@ " if lat is not None else "  ", text[:90])
    return tx_id


def replay(path: str, speed: float, loop: bool, delays: DelayEstimator) -> None:
    rows = json.loads(Path(path).read_text())
    rows.sort(key=lambda r: r["offset_sec"])
    log.info("replaying %d transmissions from %s at %gx%s", len(rows), path, speed, " (loop)" if loop else "")
    n = 0
    while True:
        t0 = time.time()
        for row in rows:
            due = t0 + row["offset_sec"] / speed
            while True:
                wait = due - time.time()
                if wait <= 0:
                    break
                time.sleep(min(wait, 1.0))
            try:
                _replay_row(row, time.time(), delays)
            except Exception:
                log.exception("failed replaying row at offset %s", row.get("offset_sec"))
            n += 1
            if n % 50 == 0:
                db.prune(config.KEEP_AUDIO_HOURS)
                _prune_audio()
        if not loop:
            log.info("replay finished")
            return
        log.info("replay loop: restarting with a fresh time base")


# --- Entry point -----------------------------------------------------------------------------

def _start_heartbeat(delays: DelayEstimator, every: float = 5.0) -> None:
    """Publish liveness + the current police delay for /api/health (the API runs in
    another process and only sees the database)."""

    def loop() -> None:
        while True:
            try:
                db.set_meta("ingest_heartbeat", f"{time.time():.0f}")
                db.set_meta("police_delay_sec", f"{delays.police_delay:.0f}")
            except Exception:
                log.exception("heartbeat failed")
            time.sleep(every)

    threading.Thread(target=loop, name="heartbeat", daemon=True).start()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", default=None, help="stream URL or local audio file (default: $STREAM_URL)")
    ap.add_argument("--replay", metavar="FIXTURE.json", help="dev mode: replay pre-extracted transmissions, no API keys needed")
    ap.add_argument("--speed", type=float, default=1.0, help="replay speed multiplier (default 1 = real time)")
    ap.add_argument("--loop", action="store_true", help="replay: restart from the top when the fixture ends")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    db.init()
    delays = DelayEstimator()
    _start_heartbeat(delays)

    if args.replay:
        if args.speed <= 0:
            raise SystemExit("--speed must be > 0")
        # Simulated minutes pass `speed` times faster, so the 30 min idle rule does too.
        incidents.start_clearer(idle_sec=config.INCIDENT_CLEAR_SEC / args.speed,
                                interval_sec=max(0.5, 60.0 / args.speed))
        replay(args.replay, args.speed, args.loop, delays)
        return
    incidents.start_clearer()

    # Transcription is the slow step; decouple it from the stream reader so a
    # long transcription never causes ffmpeg's pipe to back up.
    q: queue.Queue[tuple[float, np.ndarray] | None] = queue.Queue(maxsize=50)

    def worker() -> None:
        n = 0
        while True:
            item = q.get()
            if item is None:
                return
            heard_at, audio = item
            try:
                process(heard_at, audio, delays)
            except Exception:
                log.exception("failed processing transmission")
            n += 1
            if n % 50 == 0:
                db.prune(config.KEEP_AUDIO_HOURS)
                _prune_audio()

    t = threading.Thread(target=worker, daemon=True)
    t.start()
    for heard_at, audio in transmissions(args.source):
        try:
            q.put_nowait((heard_at, audio))
        except queue.Full:
            log.warning("transcription backlog full; dropping a transmission")
    # Only reached for local files (the stream loop reconnects forever): drain the
    # queue, then stop the worker cleanly.
    q.put(None)
    t.join()


if __name__ == "__main__":
    main()
