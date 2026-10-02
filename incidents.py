"""Group transmissions into incidents (DESIGN.md A4) and expire idle ones.

Called from `main.store()` after `db.insert`. Rules:

* A mapped transmission joins an active incident whose point is within
  150 m of the incident's point; otherwise it creates one. The incident's
  point is the first mapped transmission's point and is never averaged.
* An unmapped transmission joins the most recent active incident that shares
  any unit callsign (exact match on normalised units); otherwise it stays
  ungrouped (incident_id NULL) and only appears in the feed.
* Unit status comes from the latest transcript that names the unit.
* An incident is `active` until INCIDENT_CLEAR_SEC with no transmissions.
"""
from __future__ import annotations

import json
import logging
import re
import threading
import time
from collections.abc import Callable

import config
import db
from geo import haversine_m

log = logging.getLogger(__name__)

# Callbacks run (in the ingest thread) with the new incident dict when one is created.
on_created: list[Callable[[dict], None]] = []

_WS = re.compile(r"\s+")
_PUNCT = re.compile(r"[^\w\s]")


def normalize_unit(u: str) -> str:
    """'Engine  1,' -> 'engine 1'."""
    return _WS.sub(" ", _PUNCT.sub("", (u or "").lower())).strip()


_CLEAR = ("clear", "available", "back in service")
_ON_SCENE = ("on scene", "arrived", "ten ninety seven", "10 97")
_EN_ROUTE = ("en route", "responding", "ten seventy six", "10 76")


def unit_status(transcript: str) -> str:
    """A4 order of checks. Hyphens/extra spaces are folded so 'ten-ninety-seven' and
    '10-97' both match."""
    t = _WS.sub(" ", (transcript or "").lower().replace("-", " "))
    if any(k in t for k in _CLEAR):
        return "clear"
    if any(k in t for k in _ON_SCENE):
        return "on_scene"
    if any(k in t for k in _EN_ROUTE):
        return "en_route"
    return "dispatched"


def short_address(geocode_query: str | None, city_name: str | None = None) -> str | None:
    """'1621 N 33rd St, Lincoln, NE' -> '1621 N 33rd St'."""
    if not geocode_query:
        return None
    city_name = city_name or config.CITY_NAME
    drop = {p.strip().lower() for p in city_name.split(",")}
    drop |= {city_name.lower(), "nebraska", "ne", "usa", "united states"}
    parts = [p.strip() for p in geocode_query.split(",") if p.strip()]
    while parts and parts[-1].lower() in drop:
        parts.pop()
    return ", ".join(parts) or geocode_query


def _find_nearby_active(con, city: str, lat: float, lon: float) -> int | None:
    best_id, best_d = None, None
    rows = con.execute(
        "SELECT id, lat, lon FROM incidents WHERE city=? AND status='active' "
        "AND lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?",
        (city, lat - 0.01, lat + 0.01, lon - 0.01, lon + 0.01),
    ).fetchall()
    for r in rows:
        d = haversine_m(lat, lon, r["lat"], r["lon"])
        if d <= config.INCIDENT_JOIN_M and (best_d is None or d < best_d):
            best_id, best_d = r["id"], d
    return best_id


def _find_by_units(con, city: str, units: list[str]) -> int | None:
    if not units:
        return None
    want = set(units)
    rows = con.execute(
        "SELECT id, units FROM incidents WHERE city=? AND status='active' ORDER BY last_heard DESC, id DESC",
        (city,),
    ).fetchall()
    for r in rows:
        try:
            have = set(json.loads(r["units"] or "{}").keys())
        except ValueError:
            have = set()
        if want & have:
            return r["id"]
    return None


def assign(tx: dict) -> tuple[int | None, bool]:
    """Attach the stored transmission `tx` (a dict with its DB `id`) to an incident.

    Returns (incident_id or None, created). Updates transmissions.incident_id and
    the incident's last_heard, tx_count, units, summary/incident_type."""
    city = tx.get("city") or config.CITY_ID
    heard_at = float(tx["heard_at"])
    units = [normalize_unit(u) for u in (tx.get("units") or []) if normalize_unit(u)]
    mapped = tx.get("lat") is not None and tx.get("lon") is not None
    now = time.time()
    created = False

    with db.connect() as con:
        if mapped:
            inc_id = _find_nearby_active(con, city, float(tx["lat"]), float(tx["lon"]))
            if inc_id is None:
                cur = con.execute(
                    "INSERT INTO incidents (city, agency, incident_type, summary, address, lat, lon, "
                    "first_heard, last_heard, status, units, tx_count, reported_wrong, updated_at) "
                    "VALUES (?,?,?,?,?,?,?,?,?,'active','{}',0,0,?)",
                    (
                        city, tx.get("agency") or "unknown", tx.get("incident_type"), tx.get("summary"),
                        short_address(tx.get("geocode_query")), float(tx["lat"]), float(tx["lon"]),
                        heard_at, heard_at, now,
                    ),
                )
                inc_id = cur.lastrowid
                created = True
        else:
            inc_id = _find_by_units(con, city, units)
            if inc_id is None:
                return None, False

        row = con.execute("SELECT * FROM incidents WHERE id=?", (inc_id,)).fetchone()
        try:
            unit_map = json.loads(row["units"] or "{}")
        except ValueError:
            unit_map = {}
        status = unit_status(tx.get("transcript") or "")
        for u in units:
            unit_map[u] = status

        summary = row["summary"] or tx.get("summary")
        itype = row["incident_type"] or tx.get("incident_type")
        agency = row["agency"]
        if (not agency or agency == "unknown") and tx.get("agency") and tx["agency"] != "unknown":
            agency = tx["agency"]
        con.execute(
            "UPDATE incidents SET last_heard=MAX(last_heard, ?), first_heard=MIN(first_heard, ?), "
            "tx_count=tx_count+1, units=?, summary=?, incident_type=?, agency=?, updated_at=? WHERE id=?",
            (heard_at, heard_at, json.dumps(unit_map), summary, itype, agency, now, inc_id),
        )
        con.execute("UPDATE transmissions SET incident_id=? WHERE id=?", (inc_id, tx["id"]))

    if created:
        inc = db.incident(inc_id)
        log.info("incident #%d created: %s %s @ %s", inc_id, inc["agency"], inc["incident_type"], inc["address"])
        for cb in list(on_created):
            try:
                cb(inc)
            except Exception:
                log.exception("on_created callback failed")
    else:
        log.debug("tx #%s -> incident #%d", tx["id"], inc_id)
    return inc_id, created


def clear_idle(idle_sec: float | None = None, now: float | None = None) -> list[int]:
    """Mark active incidents with no traffic for `idle_sec` as cleared. Returns their ids."""
    idle_sec = config.INCIDENT_CLEAR_SEC if idle_sec is None else idle_sec
    now = time.time() if now is None else now
    with db.connect() as con:
        ids = [r["id"] for r in con.execute(
            "SELECT id FROM incidents WHERE status='active' AND last_heard < ?", (now - idle_sec,)
        )]
        if ids:
            qs = ",".join("?" for _ in ids)
            con.execute(f"UPDATE incidents SET status='cleared', updated_at=? WHERE id IN ({qs})", [now, *ids])
    for i in ids:
        log.info("incident #%d cleared (idle %.0fs)", i, idle_sec)
    return ids


def start_clearer(idle_sec: float | None = None, interval_sec: float = 60.0) -> threading.Thread:
    """Background thread: run clear_idle() every `interval_sec`."""

    def loop() -> None:
        while True:
            time.sleep(interval_sec)
            try:
                clear_idle(idle_sec)
            except Exception:
                log.exception("clearer failed")

    t = threading.Thread(target=loop, name="incident-clearer", daemon=True)
    t.start()
    return t
