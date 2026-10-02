"""Resolve a normalized location query to lat/lon inside the city bbox, with caching.

Nominatim is free but rate-limited (1 req/s) and weak on intersections and
business names. Mapbox handles those much better; set GEOCODER=mapbox and
MAPBOX_TOKEN to switch. Both are restricted to the city bounding box.
"""
from __future__ import annotations

import logging
import re
import sqlite3
import time

import requests

import config

log = logging.getLogger(__name__)

_last_nominatim = 0.0


def _cache() -> sqlite3.Connection:
    con = sqlite3.connect(config.DB_PATH)
    con.execute("CREATE TABLE IF NOT EXISTS geocache (q TEXT PRIMARY KEY, lat REAL, lon REAL, ok INTEGER)")
    return con


def _in_bbox(lat: float, lon: float) -> bool:
    w, s, e, n = config.BBOX
    return s <= lat <= n and w <= lon <= e


_CITY_WORD = re.escape(config.CITY_NAME.split(",")[0].strip())
_INTERSECTION = re.compile(rf"^(.*?)\s*(?:&|\band\b|@)\s*(.*?)(?:,\s*{_CITY_WORD}.*)?$", re.I)


def _nominatim(q: str) -> tuple[float, float] | None:
    global _last_nominatim
    wait = config.NOMINATIM_MIN_INTERVAL - (time.time() - _last_nominatim)
    if wait > 0:
        time.sleep(wait)
    _last_nominatim = time.time()
    w, s, e, n = config.BBOX
    r = requests.get(
        "https://nominatim.openstreetmap.org/search",
        params={"q": q, "format": "json", "limit": 1, "viewbox": f"{w},{n},{e},{s}", "bounded": 1},
        headers={"User-Agent": config.NOMINATIM_USER_AGENT},
        timeout=10,
    )
    r.raise_for_status()
    res = r.json()
    if not res:
        return None
    return float(res[0]["lat"]), float(res[0]["lon"])


def _nominatim_intersection(a: str, b: str) -> tuple[float, float] | None:
    """Nominatim can't do 'A & B'. Geocode both streets and take the midpoint
    if they're close; crude but works surprisingly often in a grid city."""
    pa = _nominatim(f"{a}, {config.CITY_NAME}")
    pb = _nominatim(f"{b}, {config.CITY_NAME}")
    if not pa or not pb:
        return None
    lat, lon = (pa[0] + pb[0]) / 2, (pa[1] + pb[1]) / 2
    # If the two street centroids are > ~3 km apart the midpoint is meaningless
    if abs(pa[0] - pb[0]) > 0.03 or abs(pa[1] - pb[1]) > 0.04:
        return None
    return lat, lon


def _mapbox(q: str) -> tuple[float, float] | None:
    w, s, e, n = config.BBOX
    r = requests.get(
        "https://api.mapbox.com/search/geocode/v6/forward",
        params={
            "q": q,
            "access_token": config.MAPBOX_TOKEN,
            "bbox": f"{w},{s},{e},{n}",
            "proximity": f"{config.MAP_CENTER[1]},{config.MAP_CENTER[0]}",
            "limit": 1,
            "country": "us",
        },
        timeout=10,
    )
    r.raise_for_status()
    feats = r.json().get("features", [])
    if not feats:
        return None
    lon, lat = feats[0]["geometry"]["coordinates"]
    return float(lat), float(lon)


def geocode(query: str, kind: str | None = None) -> tuple[float, float] | None:
    """Return (lat, lon) or None. Results (including misses) are cached."""
    q = query.strip()
    if not q:
        return None
    con = _cache()
    row = con.execute("SELECT lat, lon, ok FROM geocache WHERE q=?", (q,)).fetchone()
    if row:
        return (row[0], row[1]) if row[2] else None

    result = None
    try:
        if config.GEOCODER == "mapbox" and config.MAPBOX_TOKEN:
            result = _mapbox(q)
        else:
            m = _INTERSECTION.match(q)
            if kind == "intersection" and m:
                result = _nominatim_intersection(m.group(1), m.group(2))
            if result is None:
                result = _nominatim(q)
    except Exception as e:
        log.warning("geocode error for %r: %s", q, e)
        return None  # don't cache transient errors

    if result and not _in_bbox(*result):
        log.info("geocode outside %s, dropping: %r -> %s", config.CITY_NAME, q, result)
        result = None

    con.execute(
        "INSERT OR REPLACE INTO geocache VALUES (?,?,?,?)",
        (q, result[0] if result else None, result[1] if result else None, 1 if result else 0),
    )
    con.commit()
    con.close()
    return result
