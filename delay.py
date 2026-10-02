"""Estimate how far behind real time the police audio is.

LPD's public feed is delayed by an undisclosed, variable amount. Dispatchers
read the time on air ("time is 2314"), so when a police transmission contains
a spoken clock time we compare it to when we heard it and keep a running
estimate. Fire/EMS and Sheriff traffic on the same feed are live.
"""
from __future__ import annotations

import logging
import re
from collections import deque
from datetime import datetime, timedelta
import config

log = logging.getLogger(__name__)

# "23:14", "2314", "11:14 PM", "eleven fourteen" (whisper usually emits digits)
_TIME = re.compile(r"\b(?:time is|at|time)\s*(\d{1,2})[:\s]?(\d{2})\s*(a\.?m\.?|p\.?m\.?|hours)?\b", re.I)


class DelayEstimator:
    def __init__(self) -> None:
        self.samples: deque[float] = deque(maxlen=8)

    @property
    def police_delay(self) -> float:
        if not self.samples:
            return float(config.DEFAULT_POLICE_DELAY_SEC)
        return float(sorted(self.samples)[len(self.samples) // 2])  # median

    def observe(self, transcript: str, heard_at: float, spoken_time: str | None = None) -> None:
        """Feed a police transcript heard at `heard_at` (unix seconds)."""
        hhmm = spoken_time
        if not hhmm:
            m = _TIME.search(transcript)
            if not m:
                return
            h, mm, suffix = int(m.group(1)), int(m.group(2)), (m.group(3) or "").lower()
            if suffix.startswith("p") and h < 12:
                h += 12
            if suffix.startswith("a") and h == 12:
                h = 0
            if not (0 <= h < 24 and 0 <= mm < 60):
                return
            hhmm = f"{h:02d}:{mm:02d}"
        try:
            h, mm = map(int, hhmm.split(":"))
        except ValueError:
            return

        heard = datetime.fromtimestamp(heard_at, config.CITY_TZ)
        spoken = heard.replace(hour=h, minute=mm, second=0, microsecond=0)
        if spoken > heard:  # said "23:58", heard at 00:10 -> it was yesterday
            spoken -= timedelta(days=1)
        delay = (heard - spoken).total_seconds()
        if 0 <= delay <= 3600:  # anything over an hour is a misparse
            self.samples.append(delay)
            log.info("police delay sample %.0fs (median now %.0fs)", delay, self.police_delay)

    def actual_time(self, heard_at: float, agency: str) -> float:
        """Best estimate of when the transmission really happened."""
        if agency == "police":
            return heard_at - self.police_delay
        return heard_at
