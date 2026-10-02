"""Transcribe a transmission. Backend chosen by config.TRANSCRIBER:

* ``groq``   – POST to Groq's OpenAI-compatible endpoint, model whisper-large-v3-turbo (default)
* ``openai`` – same request shape against api.openai.com, model whisper-1
* ``local``  – faster-whisper on this machine (needs requirements-local-whisper.txt)

All three return ``(text, confidence)`` where confidence is the mean of
``exp(avg_logprob)`` over the segments. The vocabulary file is passed as the
Whisper prompt (truncated to ~224 tokens for the hosted APIs).
"""
from __future__ import annotations

import io
import logging
import math
import time
import wave
from functools import lru_cache

import numpy as np
import requests

import config

log = logging.getLogger(__name__)

PROMPT_MAX_CHARS = 900          # ≈ 224 tokens, the Whisper prompt limit
NO_SPEECH_MAX = 0.8             # drop segments Whisper thinks are silence
_warned_missing_key: set[str] = set()


# --- shared helpers ---------------------------------------------------------------------

@lru_cache(maxsize=1)
def _vocab() -> str:
    try:
        return config.VOCAB_FILE.read_text().strip()
    except FileNotFoundError:
        return ""


def _prompt(limit: int | None = None) -> str:
    p = _vocab()
    if limit and len(p) > limit:
        p = p[:limit].rsplit(" ", 1)[0]
    return p


def wav_bytes(audio: np.ndarray, rate: int = config.SAMPLE_RATE) -> bytes:
    """16-bit mono WAV in memory."""
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes((np.clip(audio, -1, 1) * 32767).astype(np.int16).tobytes())
    return buf.getvalue()


def _collect(segments: list[dict], fallback_text: str) -> tuple[str, float]:
    parts, probs = [], []
    for s in segments:
        if float(s.get("no_speech_prob", 0.0)) > NO_SPEECH_MAX:
            continue
        t = (s.get("text") or "").strip()
        if t:
            parts.append(t)
        if "avg_logprob" in s:
            probs.append(math.exp(float(s["avg_logprob"])))
    text = " ".join(parts) if parts else (fallback_text.strip() if not segments else "")
    conf = float(np.mean(probs)) if probs else (0.5 if text else 0.0)
    return text, conf


# --- hosted backends ---------------------------------------------------------------------

def _remote(audio: np.ndarray, url: str, api_key: str, model: str, backend: str) -> tuple[str, float]:
    if not api_key:
        if backend not in _warned_missing_key:
            _warned_missing_key.add(backend)
            log.error("TRANSCRIBER=%s but no API key is set; transcripts will be empty", backend)
        return "", 0.0
    files = {"file": ("clip.wav", wav_bytes(audio), "audio/wav")}
    data = {
        "model": model,
        "prompt": _prompt(PROMPT_MAX_CHARS),
        "response_format": "verbose_json",
        "language": "en",
        "temperature": "0",
    }
    delay = 1.0
    for attempt in range(4):
        try:
            r = requests.post(url, headers={"Authorization": f"Bearer {api_key}"}, files=files, data=data, timeout=60)
            if r.status_code in (429, 500, 502, 503, 504) and attempt < 3:
                log.warning("%s transcription HTTP %s; retrying in %.0fs", backend, r.status_code, delay)
                time.sleep(delay)
                delay *= 2
                continue
            r.raise_for_status()
            j = r.json()
            return _collect(j.get("segments") or [], j.get("text") or "")
        except requests.RequestException as e:
            if attempt < 3:
                log.warning("%s transcription failed (%s); retrying in %.0fs", backend, e, delay)
                time.sleep(delay)
                delay *= 2
                continue
            log.error("%s transcription failed: %s", backend, e)
    return "", 0.0


def _groq(audio: np.ndarray) -> tuple[str, float]:
    return _remote(audio, config.GROQ_URL, config.GROQ_API_KEY, config.GROQ_MODEL, "groq")


def _openai(audio: np.ndarray) -> tuple[str, float]:
    return _remote(audio, config.OPENAI_URL, config.OPENAI_API_KEY, config.OPENAI_MODEL, "openai")


# --- local backend -----------------------------------------------------------------------

@lru_cache(maxsize=1)
def _model():
    from faster_whisper import WhisperModel  # requirements-local-whisper.txt

    log.info("Loading whisper %s on %s (%s)", config.WHISPER_MODEL, config.WHISPER_DEVICE, config.WHISPER_COMPUTE)
    return WhisperModel(config.WHISPER_MODEL, device=config.WHISPER_DEVICE, compute_type=config.WHISPER_COMPUTE)


def _local(audio: np.ndarray) -> tuple[str, float]:
    segments, _info = _model().transcribe(
        audio,
        language="en",
        beam_size=5,
        initial_prompt=_prompt(),
        vad_filter=False,          # we already segmented
        condition_on_previous_text=False,  # each transmission is independent
        no_speech_threshold=0.6,
    )
    segs = [{"text": s.text, "avg_logprob": s.avg_logprob, "no_speech_prob": s.no_speech_prob} for s in segments]
    return _collect(segs, "")


# --- entry point -------------------------------------------------------------------------

def transcribe(audio: np.ndarray) -> tuple[str, float]:
    """Return (text, mean_confidence 0-1). Never raises."""
    backend = (config.TRANSCRIBER or "groq").lower()
    try:
        if backend == "groq":
            return _groq(audio)
        if backend == "openai":
            return _openai(audio)
        if backend == "local":
            return _local(audio)
        log.error("unknown TRANSCRIBER=%r (use local | groq | openai)", backend)
    except Exception as e:  # a bad clip must never take the pipeline down
        log.error("transcription (%s) failed: %s", backend, e)
    return "", 0.0
