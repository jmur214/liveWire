"""LiveWire API + the Leaflet smoke-test map.

    uvicorn server:app --host 0.0.0.0 --port 8000

Every /api/* and /audio/* request must carry `Authorization: Bearer <API_TOKEN>`
(or `?token=` for <audio> tags in the web map). Contracts: DESIGN.md B3.
"""
from __future__ import annotations

import asyncio
import json
import logging
import re
import secrets
import time
from typing import Any

from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

import config
import db
from extract import INCIDENT_TYPES
from incidents import short_address

log = logging.getLogger("livewire.api")

app = FastAPI(title="livewire", version=config.VERSION)
db.init()
if config.API_TOKEN_IS_DEFAULT:
    log.warning("API_TOKEN is not set; using the development token %r", config.API_TOKEN)

INGEST_ALIVE_SEC = 90


# --- auth + error shape --------------------------------------------------------------------

def _token_of(request: Request) -> str | None:
    h = request.headers.get("authorization", "")
    if h.lower().startswith("bearer "):
        return h[7:].strip() or None
    return request.query_params.get("token") or None


@app.middleware("http")
async def require_bearer(request: Request, call_next):
    p = request.url.path
    if p.startswith("/api/") or p.startswith("/audio/"):
        tok = _token_of(request)
        if not tok or not secrets.compare_digest(tok, config.API_TOKEN):
            return JSONResponse({"error": "unauthorized"}, status_code=401,
                                headers={"WWW-Authenticate": "Bearer"})
    return await call_next(request)


@app.exception_handler(HTTPException)
async def _http_exc(_: Request, exc: HTTPException):
    return JSONResponse({"error": str(exc.detail)}, status_code=exc.status_code, headers=exc.headers)


@app.exception_handler(RequestValidationError)
async def _validation_exc(_: Request, exc: RequestValidationError):
    return JSONResponse({"error": "invalid request", "details": exc.errors()}, status_code=422)


# --- shaping -------------------------------------------------------------------------------

def _police_delay() -> float:
    try:
        return float(db.get_meta("police_delay_sec") or config.DEFAULT_POLICE_DELAY_SEC)
    except ValueError:
        return float(config.DEFAULT_POLICE_DELAY_SEC)


def incident_json(inc: dict, meta: dict[int, dict] | None = None, delay_sec: float | None = None) -> dict:
    agency = inc.get("agency") or "unknown"
    delayed = bool(config.AGENCIES.get(agency, {}).get("delayed"))
    if delay_sec is None:
        delay_sec = _police_delay() if delayed else 0.0
    m = (meta or {}).get(inc["id"]) or db.incident_location_meta([inc["id"]]).get(inc["id"], {})
    return {
        "id": inc["id"],
        "city": inc.get("city"),
        "agency": agency,
        "incident_type": inc.get("incident_type"),
        "summary": inc.get("summary"),
        "address": inc.get("address"),
        "lat": inc["lat"],
        "lon": inc["lon"],
        "first_heard": inc["first_heard"],
        "last_heard": inc["last_heard"],
        "status": inc.get("status", "active"),
        "tx_count": inc.get("tx_count", 0),
        "units": inc.get("units") or {},
        "delayed": delayed,
        "delay_sec": int(round(delay_sec)) if delayed else 0,
        "location_kind": m.get("location_kind"),
        "location_confidence": m.get("location_confidence"),
        "heard_as": m.get("heard_as"),
        "reported_wrong": bool(inc.get("reported_wrong")),
    }


def transmission_json(tx: dict) -> dict:
    return {
        "id": tx["id"],
        "incident_id": tx.get("incident_id"),
        "agency": tx.get("agency") or "unknown",
        "incident_type": tx.get("incident_type"),
        "occurred_at": tx["occurred_at"],
        "heard_at": tx["heard_at"],
        "transcript": tx.get("transcript") or "",
        "summary": tx.get("summary"),
        "address": short_address(tx.get("geocode_query")) if tx.get("lat") is not None else None,
        "lat": tx.get("lat"),
        "lon": tx.get("lon"),
        "audio_file": tx.get("audio_file"),
        "duration": tx.get("duration"),
        "units": tx.get("units") or [],
    }


def _timeline_json(tx: dict) -> dict:
    return {
        "id": tx["id"],
        "agency": tx.get("agency") or "unknown",
        "occurred_at": tx["occurred_at"],
        "heard_at": tx["heard_at"],
        "transcript": tx.get("transcript") or "",
        "audio_file": tx.get("audio_file"),
        "duration": tx.get("duration"),
        "units": tx.get("units") or [],
        "summary": tx.get("summary"),
    }


def _city_json(c: dict) -> dict:
    return {
        "id": c["id"],
        "name": c["name"],
        "tz": c.get("tz"),
        "center": c["center"],
        "bbox": c.get("bbox"),
        "agencies": c["agencies"],
        "incident_types": INCIDENT_TYPES,
    }


# --- API -----------------------------------------------------------------------------------

@app.get("/api/health")
def health():
    hb = db.get_meta("ingest_heartbeat")
    alive = False
    if hb:
        try:
            alive = time.time() - float(hb) < INGEST_ALIVE_SEC
        except ValueError:
            alive = False
    return {
        "ok": True,
        "version": config.VERSION,
        "city": config.CITY_ID,
        "ingest_alive": alive,
        "police_delay_sec": int(round(_police_delay())),
        "last_transmission_at": db.last_transmission_at(),
    }


@app.get("/api/cities")
def cities():
    return {"cities": [_city_json(c) for c in config.all_cities()]}


@app.get("/api/incidents")
def incidents(
    hours: float = Query(2.0, ge=0.1, le=48),
    agencies: str | None = Query(None, description="comma-separated: police,fire,sheriff"),
):
    ags = [a.strip().lower() for a in agencies.split(",") if a.strip()] if agencies else None
    rows = db.incidents_recent(hours=hours, agencies=ags, city=config.CITY_ID)
    meta = db.incident_location_meta([r["id"] for r in rows])
    delay = _police_delay()
    return {"incidents": [incident_json(r, meta, delay) for r in rows]}


@app.get("/api/incidents/{inc_id}")
def incident_detail(inc_id: int):
    inc = db.incident(inc_id)
    if not inc:
        raise HTTPException(404, "incident not found")
    out = incident_json(inc)
    out["transmissions"] = [_timeline_json(t) for t in db.incident_transmissions(inc_id)]
    return out


@app.get("/api/transmissions")
def transmissions(
    since_id: int | None = Query(None, ge=0),
    limit: int = Query(200, ge=1, le=1000),
):
    rows = db.transmissions_since(since_id, limit)
    latest = rows[-1]["id"] if rows else (since_id if since_id is not None else db.latest_transmission_id())
    return {"transmissions": [transmission_json(r) for r in rows], "latest_id": latest}


class ReportBody(BaseModel):
    incident_id: int
    reason: str = Field("wrong_location", max_length=64)


@app.post("/api/report")
def report(body: ReportBody):
    if not db.report_wrong(body.incident_id):
        raise HTTPException(404, "incident not found")
    log.info("incident #%d reported: %s", body.incident_id, body.reason)
    return {"ok": True}


# --- devices (alerts) ----------------------------------------------------------------------

class DeviceBody(BaseModel):
    token: str = Field(min_length=16, max_length=400)
    city: str = "lincoln"
    sandbox: bool = True
    rules: dict[str, Any] = Field(default_factory=dict)


_HEX = re.compile(r"^[0-9a-f]{16,}$")


@app.post("/api/device")
def device(body: DeviceBody):
    """Register / update a device's APNs token and alert rules (B3). The rules blob
    also carries `sandbox` (dev build → APNs sandbox) and `last_location`."""
    token = body.token.strip().lower()
    if not _HEX.match(token):
        raise HTTPException(400, "token must be the APNs device token as hex")
    if body.city not in {c["id"] for c in config.all_cities()}:
        raise HTTPException(400, f"unknown city {body.city!r}")
    rules = dict(body.rules)
    rules["sandbox"] = body.sandbox
    prev = db.device(token)
    if prev and not rules.get("last_location") and prev["rules"].get("last_location"):
        rules["last_location"] = prev["rules"]["last_location"]   # a rules-only update keeps the last fix
    db.upsert_device(token, body.city, rules)
    log.info("device %s… registered (%s, enabled=%s)", token[:8], body.city, bool(rules.get("enabled")))
    return {"ok": True, "stats": db.alert_stats(token)}


# --- SSE -----------------------------------------------------------------------------------

STREAM_POLL_SEC = 0.5
STREAM_PING_SEC = 15.0


def _sse(event: str, data: Any) -> str:
    return f"event: {event}\ndata: {json.dumps(data, separators=(',', ':'))}\n\n"


def _poll_changes(last_tx_id: int, last_inc_ts: float, sent: dict[int, float]):
    """One poll of the database (runs in a worker thread)."""
    txs = db.transmissions_since(last_tx_id, 500)
    incs = [i for i in db.incidents_updated_since(last_inc_ts - 0.001) if sent.get(i["id"]) != i["updated_at"]]
    meta = db.incident_location_meta([i["id"] for i in incs]) if incs else {}
    delay = _police_delay() if incs else 0.0
    return txs, incs, meta, delay


@app.get("/api/stream")
async def stream(request: Request, since_id: int | None = Query(None, ge=0)):
    """text/event-stream of `transmission`, `incident` and `ping` events.

    Ingest runs in another process, so this polls SQLite twice a second: new
    transmission ids and incidents whose `updated_at` moved (create, update,
    cleared). `since_id` replays transmissions missed while disconnected."""

    async def gen():
        last_tx_id = since_id if since_id is not None else await asyncio.to_thread(db.latest_transmission_id)
        last_inc_ts = time.time()
        sent: dict[int, float] = {}
        last_ping = time.time()
        yield ": connected\n\n"
        while True:
            if await request.is_disconnected():
                return
            try:
                txs, incs, meta, delay = await asyncio.to_thread(_poll_changes, last_tx_id, last_inc_ts, sent)
            except Exception:
                log.exception("stream poll failed")
                txs, incs, meta, delay = [], [], {}, 0.0
            for inc in incs:
                sent[inc["id"]] = inc["updated_at"]
                last_inc_ts = max(last_inc_ts, inc["updated_at"])
                yield _sse("incident", incident_json(inc, meta, delay if inc.get("agency") in config.AGENCIES and config.AGENCIES[inc["agency"]].get("delayed") else 0.0))
            for tx in txs:
                last_tx_id = max(last_tx_id, tx["id"])
                yield _sse("transmission", transmission_json(tx))
            if len(sent) > 2000:
                for k in list(sent)[:1000]:
                    sent.pop(k, None)
            now = time.time()
            if now - last_ping >= STREAM_PING_SEC:
                last_ping = now
                yield _sse("ping", {})
            await asyncio.sleep(STREAM_POLL_SEC)

    return StreamingResponse(
        gen(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no", "Connection": "keep-alive"},
    )


# --- legacy endpoints used by static/index.html --------------------------------------------

@app.get("/api/events")
def events(hours: float = Query(2.0, ge=0.1, le=48), mapped: bool = True):
    return {"center": config.MAP_CENTER, "events": db.recent(hours=hours, mapped_only=mapped)}


@app.get("/api/transcript")
def transcript(hours: float = Query(1.0, ge=0.1, le=48)):
    """Everything heard, mapped or not — the scrolling 'what are they saying' feed."""
    return {"events": db.recent(hours=hours, mapped_only=False)}


@app.get("/")
def index():
    return FileResponse(config.ROOT / "static" / "index.html")


app.mount("/audio", StaticFiles(directory=config.AUDIO_DIR), name="audio")
app.mount("/static", StaticFiles(directory=config.ROOT / "static"), name="static")
