"""Pipeline orchestrator: stream -> VAD -> whisper -> extract -> geocode -> sqlite.

Run alongside server.py (the map). Usage:
    STREAM_URL=https://... ANTHROPIC_API_KEY=... python main.py
    python main.py --source tests/sample.mp3      # test on a local recording
"""
from __future__ import annotations

import argparse
import logging
import queue
import threading
import time
import wave

import numpy as np

import config
import db
from delay import DelayEstimator
from extract import extract
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


def process(heard_at: float, audio: np.ndarray, delays: DelayEstimator) -> None:
    duration = len(audio) / config.SAMPLE_RATE
    text, asr_conf = transcribe(audio)
    if not text:
        return
    log.info("[%4.1fs] %s", duration, text)

    inc = extract(text)
    if inc.agency == "police" or inc.spoken_time:
        delays.observe(text, heard_at, inc.spoken_time)

    lat = lon = None
    if inc.mappable:
        pt = geocode(inc.geocode_query, inc.location_kind)
        if pt:
            lat, lon = pt
            log.info("   -> %s @ %.4f,%.4f", inc.geocode_query, lat, lon)
        else:
            log.info("   -> could not geocode %r", inc.geocode_query)

    db.insert(
        {
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
            "units": inc.units,
            "summary": inc.summary,
            "extract_confidence": inc.confidence,
            "lat": lat,
            "lon": lon,
        }
    )


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", default=None, help="stream URL or local audio file (default: $STREAM_URL)")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    db.init()
    delays = DelayEstimator()

    # Transcription is the slow step; decouple it from the stream reader so a
    # long transcription never causes ffmpeg's pipe to back up.
    q: queue.Queue[tuple[float, np.ndarray]] = queue.Queue(maxsize=50)

    def worker() -> None:
        n = 0
        while True:
            heard_at, audio = q.get()
            try:
                process(heard_at, audio, delays)
            except Exception:
                log.exception("failed processing transmission")
            n += 1
            if n % 50 == 0:
                db.prune(config.KEEP_AUDIO_HOURS)
                _prune_audio()

    threading.Thread(target=worker, daemon=True).start()
    for heard_at, audio in transmissions(args.source):
        try:
            q.put_nowait((heard_at, audio))
        except queue.Full:
            log.warning("transcription backlog full; dropping a transmission")
    # Only reached for local files (the stream loop reconnects forever).
    while not q.empty():
        time.sleep(0.5)
    time.sleep(1)  # let the worker finish its last item


if __name__ == "__main__":
    main()
