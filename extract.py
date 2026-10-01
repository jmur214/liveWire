"""Turn a transcript into a structured incident with Claude.

Dispatch audio is terse and local: "Baker 12, 27th and Vine, disturbance" or
"the Casey's on Cornhusker". The model's job is to normalize that into
something a geocoder can resolve, and to say when there's nothing to map.
"""
from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass, field

import config

log = logging.getLogger(__name__)

SYSTEM = """You extract structured incident data from police/fire radio transcripts in Lincoln, Nebraska.
The transcripts come from automatic speech recognition and contain errors. Be conservative.

Return ONLY a JSON object with these keys:
- agency: "police" | "fire" | "sheriff" | "unknown"
- incident_type: short lowercase category, e.g. "disturbance", "traffic stop", "injury accident",
  "medical", "structure fire", "welfare check", "theft", "suspicious person", "pursuit", or null
- location_text: the location exactly as spoken, or null
- geocode_query: a normalized query a geocoder can resolve inside Lincoln NE, or null. Rules:
    * intersections -> "N 27th St & Vine St, Lincoln, NE" (expand abbreviations, keep N/S/E/W if said)
    * addresses -> "1234 S 48th St, Lincoln, NE"
    * businesses with a street -> "Casey's, Cornhusker Hwy, Lincoln, NE"
    * highways/interstates with a cross street or mile marker -> include both
    * if only a unit callsign or no place is mentioned -> null
- location_kind: "intersection" | "address" | "business" | "landmark" | "highway" | null
- units: list of unit callsigns mentioned, e.g. ["Baker 12", "Engine 5"]
- spoken_time: a clock time the dispatcher read aloud, as "HH:MM" 24h, or null
- summary: one short sentence of what is happening, or null if it's just an acknowledgement
- confidence: 0.0-1.0 that the location is real and correctly resolved

Lincoln conventions: lettered streets run east-west (A St through Y St, with O St the main one);
numbered streets run north-south, and "27th" means N 27th or S 27th depending on side of O St.
If the side isn't stated, omit the prefix. Common names: Cornhusker Hwy, Capitol Pkwy,
Nebraska Pkwy, Old Cheney Rd, Pioneers Blvd, Van Dorn St, Holdrege St, Superior St, Highway 2, I-80.
"""


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
    inc.units = list(inc.units or [])
    inc.confidence = float(inc.confidence or 0)
    return inc


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
