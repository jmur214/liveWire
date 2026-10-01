"""SQLite storage for transmissions and mapped incidents."""
from __future__ import annotations

import json
import sqlite3
import time
from contextlib import contextmanager

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
    lon REAL
);
CREATE INDEX IF NOT EXISTS ix_tx_occurred ON transmissions(occurred_at);
CREATE INDEX IF NOT EXISTS ix_tx_mapped ON transmissions(lat) WHERE lat IS NOT NULL;
"""


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
        con.executescript(SCHEMA)


def insert(row: dict) -> int:
    row = dict(row)
    if isinstance(row.get("units"), list):
        row["units"] = json.dumps(row["units"])
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
        rows = [dict(r) for r in con.execute(sql, (since,))]
    for r in rows:
        try:
            r["units"] = json.loads(r["units"] or "[]")
        except (TypeError, ValueError):
            r["units"] = []
    return rows


def prune(hours: float) -> None:
    with connect() as con:
        con.execute("DELETE FROM transmissions WHERE heard_at < ?", (time.time() - hours * 3600,))
