"""SQLite storage: transmissions, incidents, devices, alerts, meta."""
from __future__ import annotations

import json
import sqlite3
import time
from contextlib import contextmanager
from typing import Any

import config

SCHEMA = """
CREATE TABLE IF NOT EXISTS transmissions (
    id INTEGER PRIMARY KEY,
    heard_at REAL NOT NULL,        -- when we received it (unix)
    occurred_at REAL NOT NULL,     -- heard_at minus estimated delay
    duration REAL,
    transcript TEXT,
    asr_confidence REAL,
    audio_file TEXT,
    agency TEXT,
    incident_type TEXT,
    location_text TEXT,
    geocode_query TEXT,
    units TEXT,                    -- JSON list
    summary TEXT,
    extract_confidence REAL,
    lat REAL,
    lon REAL,
    incident_id INTEGER REFERENCES incidents(id),
    city TEXT NOT NULL DEFAULT 'lincoln',
    location_kind TEXT
);
CREATE INDEX IF NOT EXISTS ix_tx_occurred ON transmissions(occurred_at);
CREATE INDEX IF NOT EXISTS ix_tx_mapped ON transmissions(lat) WHERE lat IS NOT NULL;

CREATE TABLE IF NOT EXISTS incidents (
    id INTEGER PRIMARY KEY,
    city TEXT NOT NULL,
    agency TEXT, incident_type TEXT, summary TEXT, address TEXT,
    lat REAL NOT NULL, lon REAL NOT NULL,
    first_heard REAL NOT NULL, last_heard REAL NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',      -- active | cleared
    units TEXT NOT NULL DEFAULT '{}',           -- JSON {"engine 1":"en_route",...}
    tx_count INTEGER NOT NULL DEFAULT 0,
    reported_wrong INTEGER NOT NULL DEFAULT 0,
    updated_at REAL NOT NULL DEFAULT 0          -- last change of any kind (drives /api/stream)
);
CREATE INDEX IF NOT EXISTS ix_inc_last ON incidents(last_heard);
CREATE INDEX IF NOT EXISTS ix_inc_updated ON incidents(updated_at);

CREATE TABLE IF NOT EXISTS devices (
    token TEXT PRIMARY KEY,                     -- APNs hex token
    city TEXT NOT NULL,
    rules TEXT NOT NULL,                        -- JSON, shape in DESIGN.md B3 /api/device
    updated_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS alerts_sent (
    id INTEGER PRIMARY KEY, token TEXT, incident_id INTEGER, sent_at REAL,
    reason TEXT                                 -- "type:<t>" | "place:<name>" | "near_me"
);
CREATE INDEX IF NOT EXISTS ix_alerts_tok_inc ON alerts_sent(token, incident_id);

CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
"""

# Applied after SCHEMA for databases created before these columns existed.
MIGRATIONS = [
    "ALTER TABLE transmissions ADD COLUMN incident_id INTEGER REFERENCES incidents(id)",
    "ALTER TABLE transmissions ADD COLUMN city TEXT NOT NULL DEFAULT 'lincoln'",
    "ALTER TABLE transmissions ADD COLUMN location_kind TEXT",
    "ALTER TABLE incidents ADD COLUMN updated_at REAL NOT NULL DEFAULT 0",
    "ALTER TABLE alerts_sent ADD COLUMN reason TEXT",
    "CREATE INDEX IF NOT EXISTS ix_tx_inc ON transmissions(incident_id)",
]


@contextmanager
def connect():
    con = sqlite3.connect(config.DB_PATH, timeout=10)
    con.row_factory = sqlite3.Row
    try:
        yield con
        con.commit()
    finally:
        con.close()


def init() -> None:
    with connect() as con:
        con.execute("PRAGMA journal_mode=WAL")
        con.executescript(SCHEMA)
        for sql in MIGRATIONS:
            try:
                con.execute(sql)
            except sqlite3.OperationalError as e:
                if "duplicate column" not in str(e).lower():
                    raise


# --- helpers -----------------------------------------------------------------------------

def _loads(s: Any, default: Any) -> Any:
    if s is None:
        return default
    try:
        return json.loads(s)
    except (TypeError, ValueError):
        return default


def tx_dict(r: sqlite3.Row | dict) -> dict:
    d = dict(r)
    d["units"] = _loads(d.get("units"), [])
    if not isinstance(d["units"], list):
        d["units"] = []
    return d


def inc_dict(r: sqlite3.Row | dict) -> dict:
    d = dict(r)
    d["units"] = _loads(d.get("units"), {})
    if not isinstance(d["units"], dict):
        d["units"] = {}
    return d


# --- meta --------------------------------------------------------------------------------

def set_meta(key: str, value: Any) -> None:
    with connect() as con:
        con.execute("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", (key, str(value)))


def get_meta(key: str, default: str | None = None) -> str | None:
    with connect() as con:
        row = con.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
    return row[0] if row else default


# --- transmissions -----------------------------------------------------------------------

def insert(row: dict) -> int:
    row = dict(row)
    if isinstance(row.get("units"), list):
        row["units"] = json.dumps(row["units"])
    row.setdefault("city", config.CITY_ID)
    cols = ", ".join(row)
    qs = ", ".join("?" for _ in row)
    with connect() as con:
        cur = con.execute(f"INSERT INTO transmissions ({cols}) VALUES ({qs})", list(row.values()))
        return cur.lastrowid


def recent(hours: float = 2.0, mapped_only: bool = False) -> list[dict]:
    since = time.time() - hours * 3600
    sql = "SELECT * FROM transmissions WHERE occurred_at >= ?"
    if mapped_only:
        sql += " AND lat IS NOT NULL"
    sql += " ORDER BY occurred_at DESC LIMIT 500"
    with connect() as con:
        return [tx_dict(r) for r in con.execute(sql, (since,))]


def transmission(tx_id: int) -> dict | None:
    with connect() as con:
        r = con.execute("SELECT * FROM transmissions WHERE id=?", (tx_id,)).fetchone()
    return tx_dict(r) if r else None


def transmissions_since(since_id: int | None, limit: int = 200) -> list[dict]:
    """Rows in id-ascending order. With since_id: rows after it; without: the last `limit`."""
    with connect() as con:
        if since_id is None:
            rows = con.execute(
                "SELECT * FROM (SELECT * FROM transmissions ORDER BY id DESC LIMIT ?) ORDER BY id ASC",
                (limit,),
            )
        else:
            rows = con.execute(
                "SELECT * FROM transmissions WHERE id > ? ORDER BY id ASC LIMIT ?", (since_id, limit)
            )
        return [tx_dict(r) for r in rows]


def latest_transmission_id() -> int:
    with connect() as con:
        r = con.execute("SELECT MAX(id) FROM transmissions").fetchone()
    return int(r[0] or 0)


def last_transmission_at() -> float | None:
    with connect() as con:
        r = con.execute("SELECT MAX(heard_at) FROM transmissions").fetchone()
    return float(r[0]) if r and r[0] is not None else None


def incident_transmissions(inc_id: int) -> list[dict]:
    with connect() as con:
        rows = con.execute(
            "SELECT * FROM transmissions WHERE incident_id=? ORDER BY occurred_at DESC, id DESC", (inc_id,)
        )
        return [tx_dict(r) for r in rows]


# --- incidents ---------------------------------------------------------------------------

def incidents_recent(hours: float, agencies: list[str] | None = None, city: str | None = None) -> list[dict]:
    since = time.time() - hours * 3600
    sql = "SELECT * FROM incidents WHERE last_heard >= ?"
    args: list[Any] = [since]
    if city:
        sql += " AND city = ?"
        args.append(city)
    if agencies:
        sql += " AND agency IN (%s)" % ",".join("?" for _ in agencies)
        args.extend(agencies)
    sql += " ORDER BY last_heard DESC LIMIT 500"
    with connect() as con:
        return [inc_dict(r) for r in con.execute(sql, args)]


def incident(inc_id: int) -> dict | None:
    with connect() as con:
        r = con.execute("SELECT * FROM incidents WHERE id=?", (inc_id,)).fetchone()
    return inc_dict(r) if r else None


def incidents_updated_since(ts: float) -> list[dict]:
    with connect() as con:
        rows = con.execute("SELECT * FROM incidents WHERE updated_at > ? ORDER BY updated_at ASC", (ts,))
        return [inc_dict(r) for r in rows]


def incident_location_meta(ids: list[int]) -> dict[int, dict]:
    """Per incident: location_kind / confidence / literal phrase of its first mapped transmission."""
    if not ids:
        return {}
    qs = ",".join("?" for _ in ids)
    sql = f"""SELECT incident_id, MIN(id) AS first_id, location_kind, extract_confidence, location_text
              FROM transmissions WHERE incident_id IN ({qs}) AND lat IS NOT NULL GROUP BY incident_id"""
    out: dict[int, dict] = {}
    with connect() as con:
        for r in con.execute(sql, ids):
            out[r["incident_id"]] = {
                "location_kind": r["location_kind"],
                "location_confidence": r["extract_confidence"],
                "heard_as": r["location_text"],
            }
    return out


def report_wrong(inc_id: int) -> bool:
    with connect() as con:
        cur = con.execute(
            "UPDATE incidents SET reported_wrong=1, updated_at=? WHERE id=?", (time.time(), inc_id)
        )
        return cur.rowcount > 0


# --- devices -----------------------------------------------------------------------------

def upsert_device(token: str, city: str, rules: dict) -> None:
    with connect() as con:
        con.execute(
            "INSERT OR REPLACE INTO devices (token, city, rules, updated_at) VALUES (?,?,?,?)",
            (token, city, json.dumps(rules), time.time()),
        )


def device(token: str) -> dict | None:
    with connect() as con:
        r = con.execute("SELECT * FROM devices WHERE token=?", (token,)).fetchone()
    if not r:
        return None
    d = dict(r)
    d["rules"] = _loads(d["rules"], {})
    return d


def devices_in(city: str) -> list[dict]:
    with connect() as con:
        rows = con.execute("SELECT * FROM devices WHERE city=?", (city,)).fetchall()
    out = []
    for r in rows:
        d = dict(r)
        d["rules"] = _loads(d["rules"], {})
        out.append(d)
    return out


def alert_already_sent(token: str, incident_id: int) -> bool:
    with connect() as con:
        r = con.execute(
            "SELECT 1 FROM alerts_sent WHERE token=? AND incident_id=? LIMIT 1", (token, incident_id)
        ).fetchone()
    return r is not None


def record_alert(token: str, incident_id: int, reason: str | None = None) -> None:
    with connect() as con:
        con.execute(
            "INSERT INTO alerts_sent (token, incident_id, sent_at, reason) VALUES (?,?,?,?)",
            (token, incident_id, time.time(), reason),
        )


def delete_device(token: str) -> None:
    with connect() as con:
        con.execute("DELETE FROM devices WHERE token=?", (token,))


def alert_stats(token: str) -> dict:
    """Alerts in the last 7 days for the Alerts screen: total, per place, by type, near-me."""
    since = time.time() - 7 * 86400
    stats: dict = {"week_total": 0, "places": [], "types": 0, "near_me": 0}
    per_place: dict[str, int] = {}
    with connect() as con:
        for r in con.execute("SELECT reason, COUNT(*) n FROM alerts_sent WHERE token=? AND sent_at >= ? GROUP BY reason",
                             (token, since)):
            reason, n = r["reason"] or "", int(r["n"])
            stats["week_total"] += n
            if reason.startswith("place:"):
                per_place[reason[6:]] = per_place.get(reason[6:], 0) + n
            elif reason.startswith("type:"):
                stats["types"] += n
            elif reason == "near_me":
                stats["near_me"] += n
    stats["places"] = [{"name": k, "count": v} for k, v in sorted(per_place.items())]
    return stats


# --- housekeeping ------------------------------------------------------------------------

def prune(hours: float) -> None:
    now = time.time()
    with connect() as con:
        con.execute("DELETE FROM transmissions WHERE heard_at < ?", (now - hours * 3600,))
        con.execute("DELETE FROM incidents WHERE last_heard < ?", (now - config.KEEP_INCIDENT_DAYS * 86400,))
        con.execute("DELETE FROM alerts_sent WHERE sent_at < ?", (now - config.KEEP_INCIDENT_DAYS * 86400,))
