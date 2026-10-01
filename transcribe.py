"""Transcribe a transmission with faster-whisper, primed with Lincoln vocabulary."""
from __future__ import annotations

import logging
from functools import lru_cache

import numpy as np

import config

log = logging.getLogger(__name__)


@lru_cache(maxsize=1)
def _model():
    from faster_whisper import WhisperModel

    log.info("Loading whisper %s on %s (%s)", config.WHISPER_MODEL, config.WHISPER_DEVICE, config.WHISPER_COMPUTE)
    return WhisperModel(config.WHISPER_MODEL, device=config.WHISPER_DEVICE, compute_type=config.WHISPER_COMPUTE)


@lru_cache(maxsize=1)
def _prompt() -> str:
    try:
        return config.VOCAB_FILE.read_text().strip()
    except FileNotFoundError:
        return ""


def transcribe(audio: np.ndarray) -> tuple[str, float]:
    """Return (text, mean_confidence 0-1)."""
    segments, _info = _model().transcribe(
        audio,
        language="en",
        beam_size=5,
        initial_prompt=_prompt(),
        vad_filter=False,          # we already segmented
        condition_on_previous_text=False,  # each transmission is independent
        no_speech_threshold=0.6,
    )
    parts, probs = [], []
    for s in segments:
        if s.no_speech_prob > 0.8:
            continue
        parts.append(s.text.strip())
        probs.append(np.exp(s.avg_logprob))
    text = " ".join(p for p in parts if p)
    conf = float(np.mean(probs)) if probs else 0.0
    return text, conf
