"""Pull audio from the stream with ffmpeg and cut it into individual transmissions.

Yields (start_wallclock, numpy float32 mono 16 kHz) tuples, one per transmission.
Uses Silero VAD (via torch) to find speech; falls back to a simple energy gate
if torch isn't available so you can at least smoke-test the pipeline.
"""
from __future__ import annotations

import logging
import subprocess
import time
from collections.abc import Iterator

import numpy as np

import config

log = logging.getLogger(__name__)

FRAME_MS = 32  # Silero wants 512-sample windows at 16 kHz = 32 ms
FRAME_SAMPLES = config.SAMPLE_RATE * FRAME_MS // 1000


def _ffmpeg_pcm(source: str) -> subprocess.Popen:
    """Start ffmpeg decoding `source` to raw s16le mono 16 kHz on stdout."""
    cmd = ["ffmpeg", "-loglevel", "error", "-nostdin"]
    if config.STREAM_HEADERS and source.startswith("http"):
        cmd += ["-headers", config.STREAM_HEADERS]
    if source.startswith("http"):
        cmd += ["-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "10"]
    else:
        cmd += ["-re"]  # play local files at real-time speed so timestamps make sense
    cmd += ["-i", source, "-f", "s16le", "-ac", "1", "-ar", str(config.SAMPLE_RATE), "-"]
    return subprocess.Popen(cmd, stdout=subprocess.PIPE, bufsize=FRAME_SAMPLES * 2 * 50)


class _SpeechDetector:
    """Returns True for frames that contain speech."""

    def __init__(self) -> None:
        self.model = None
        try:
            import torch  # noqa: F401

            self.model, _ = torch.hub.load("snakers4/silero-vad", "silero_vad", trust_repo=True)
            self._torch = torch
            log.info("Using Silero VAD")
        except Exception as e:  # pragma: no cover
            log.warning("Silero VAD unavailable (%s); falling back to energy gate", e)

    def __call__(self, frame: np.ndarray) -> bool:
        if self.model is not None:
            t = self._torch.from_numpy(frame)
            return float(self.model(t, config.SAMPLE_RATE).item()) > 0.5
        return float(np.sqrt(np.mean(frame**2))) > 0.01


def transmissions(source: str | None = None) -> Iterator[tuple[float, np.ndarray]]:
    """Generator of (wallclock_start, audio) for each detected transmission."""
    source = source or config.STREAM_URL
    if not source:
        raise SystemExit("No STREAM_URL set. See config.py / README.")

    detector = _SpeechDetector()
    silence_frames_needed = int(config.SILENCE_SEC * 1000 / FRAME_MS)
    max_frames = int(config.MAX_SEGMENT_SEC * 1000 / FRAME_MS)

    while True:  # reconnect loop
        proc = _ffmpeg_pcm(source)
        log.info("ffmpeg started for %s", source)
        buf: list[np.ndarray] = []
        seg_start: float | None = None
        silence_run = 0
        try:
            while True:
                raw = proc.stdout.read(FRAME_SAMPLES * 2)
                if len(raw) < FRAME_SAMPLES * 2:
                    break
                frame = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
                speech = detector(frame)

                if speech:
                    if seg_start is None:
                        seg_start = time.time()
                    silence_run = 0
                    buf.append(frame)
                elif seg_start is not None:
                    silence_run += 1
                    buf.append(frame)  # keep the trailing silence, Whisper likes padding

                done = seg_start is not None and (
                    silence_run >= silence_frames_needed or len(buf) >= max_frames
                )
                if done:
                    audio = np.concatenate(buf)
                    dur = len(audio) / config.SAMPLE_RATE
                    if dur >= config.MIN_SEGMENT_SEC:
                        yield seg_start, audio
                    buf, seg_start, silence_run = [], None, 0
        finally:
            proc.kill()

        if not source.startswith("http"):
            log.info("Local source finished")
            return
        log.warning("Stream ended; reconnecting in 5 s")
        time.sleep(5)
