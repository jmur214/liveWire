"""Turn a transcript into a structured incident with Claude.

Dispatch audio is terse and local: "Baker 12, 27th and Vine, disturbance" or
"the Casey's on Cornhusker". The model's job is to normalize that into
something a geocoder can resolve, and to say when there's nothing to map.
"""
from __future__ import annotations

import difflib
import json
import logging
import re
from dataclasses import dataclass, field

import config

log = logging.getLogger(__name__)

INCIDENT_TYPES = [
    "structure fire", "vehicle fire", "grass fire", "fire alarm", "gas leak", "medical",
    "injury accident", "non-injury accident", "hit and run", "traffic stop", "disturbance",
    "domestic", "assault", "shooting", "stabbing", "robbery", "burglary", "theft", "shoplifting",
    "suspicious person", "suspicious vehicle", "welfare check", "trespass", "pursuit",
    "missing person", "overdose", "water rescue", "hazmat", "other",
]

# City-neutral template; the city config supplies the local conventions (`extract_hints`).
SYSTEM_TEMPLATE = """You extract structured incident data from police/fire radio transcripts in {city_name}.
The transcripts come from automatic speech recognition and contain errors. Be conservative.

Return ONLY a JSON object with these keys:
- agency: "police" | "fire" | "sheriff" | "unknown"
- incident_type: exactly one of: {types}; or null if the transmission is just an acknowledgement
  or nothing is happening. Pick the closest category; use "other" only when none fits.
- location_text: the location exactly as spoken, or null
- geocode_query: a normalized query a geocoder can resolve inside {city_name}, or null. Rules:
    * intersections -> "N 27th St & Vine St, {city_name}" (expand abbreviations, keep N/S/E/W if said)
    * addresses -> "1234 S 48th St, {city_name}"
    * businesses with a street -> "Casey's, Cornhusker Hwy, {city_name}"
    * highways/interstates with a cross street or mile marker -> include both
    * if only a unit callsign or no place is mentioned -> null
- location_kind: "intersection" | "address" | "business" | "landmark" | "highway" | null
- units: list of unit callsigns mentioned, e.g. ["Baker 12", "Engine 5"]
- spoken_time: a clock time the dispatcher read aloud, as "HH:MM" 24h, or null
- summary: one short sentence of what is happening, or null if it's just an acknowledgement
- confidence: 0.0-1.0 that the location is real and correctly resolved

{hints}
"""

SYSTEM = SYSTEM_TEMPLATE.format(
    city_name=config.CITY_NAME, types=", ".join(f'"{t}"' for t in INCIDENT_TYPES), hints=config.EXTRACT_HINTS
).strip() + "\n"


@dataclass
class Incident:
    agency: str = "unknown"
    incident_type: str | None = None
    location_text: str | None = None
    geocode_query: str | None = None
    location_kind: str | None = None
    units: list[str] = field(default_factory=list)
    spoken_time: str | None = None
    summary: str | None = None
    confidence: float = 0.0

    @property
    def mappable(self) -> bool:
        return bool(self.geocode_query) and self.confidence >= 0.4


_FENCE = re.compile(r"```(?:json)?\s*(.*?)```", re.S)


def _parse(raw: str) -> Incident:
    m = _FENCE.search(raw)
    if m:
        raw = m.group(1)
    data = json.loads(raw)
    inc = Incident()
    for k, v in data.items():
        if hasattr(inc, k):
            setattr(inc, k, v)
    inc.units = [str(u) for u in (inc.units or []) if u]
    inc.confidence = float(inc.confidence or 0)
    inc.incident_type = normalize_type(inc.incident_type)
    return inc


_TYPE_ALIASES = {
    "shots fired": "shooting", "shot": "shooting", "gunshot": "shooting", "fight": "disturbance",
    "ems": "medical", "ems call": "medical", "medical emergency": "medical", "cardiac": "medical",
    "mva": "non-injury accident", "accident": "non-injury accident", "crash": "non-injury accident",
    "mvc": "non-injury accident", "rollover": "injury accident", "fire": "structure fire",
    "house fire": "structure fire", "car fire": "vehicle fire", "brush fire": "grass fire",
    "alarm": "fire alarm", "odor of gas": "gas leak", "larceny": "theft", "stolen vehicle": "theft",
    "dui": "traffic stop", "check welfare": "welfare check", "od": "overdose",
    "hazardous materials": "hazmat", "chemical spill": "hazmat",
}


def _stem(w: str) -> str:
    if w.endswith("ies"):
        return w[:-3] + "y"
    if w.endswith("s") and len(w) > 3:
        return w[:-1]
    return w


def normalize_type(t: str | None) -> str | None:
    """Constrain a model-supplied type to INCIDENT_TYPES: exact, alias, substring,
    word overlap, then a strict fuzzy match; anything else -> "other". None stays None."""
    if not t:
        return None
    t = " ".join(str(t).lower().replace("_", " ").split())
    flat = t.replace("-", " ")
    if t in INCIDENT_TYPES:
        return t
    if flat in INCIDENT_TYPES:
        return flat
    if flat in _TYPE_ALIASES:
        return _TYPE_ALIASES[flat]
    contained = [c for c in INCIDENT_TYPES if c.replace("-", " ") in flat]
    if contained:
        return max(contained, key=len)   # "non-injury accident" beats "injury accident"
    words = {_stem(w) for w in flat.split()}
    best, best_score = None, 0
    for c in INCIDENT_TYPES:
        cw = {_stem(w) for w in c.replace("-", " ").split()}
        score = len(words & cw)
        if "non" in cw and "non" not in words:
            score -= 1   # don't let "accident with injuries" land on the non-injury type
        if score > best_score or (score == best_score and best and score > 0 and len(cw) < len(set(best.replace("-", " ").split()))):
            best, best_score = c, score
    if best and best_score > 0:
        return best
    close = difflib.get_close_matches(flat, INCIDENT_TYPES, n=1, cutoff=0.8)
    if close:
        return close[0]
    return "other"


def extract(transcript: str) -> Incident:
    """Extract an Incident. Never raises; returns an empty Incident on failure."""
    transcript = transcript.strip()
    if len(transcript) < config.MIN_TRANSCRIPT_CHARS:
        return Incident()
    if not config.ANTHROPIC_API_KEY:
        log.warning("ANTHROPIC_API_KEY not set; skipping extraction")
        return Incident()
    try:
        import anthropic

        client = anthropic.Anthropic(api_key=config.ANTHROPIC_API_KEY)
        msg = client.messages.create(
            model=config.EXTRACT_MODEL,
            max_tokens=400,
            system=SYSTEM,
            messages=[{"role": "user", "content": f"Transcript:\n{transcript}"}],
        )
        return _parse(msg.content[0].text)
    except Exception as e:
        log.error("extraction failed: %s", e)
        return Incident()
