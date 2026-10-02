"""APNs alerts (DESIGN.md B2.6).

Evaluated once per *incident creation* for every device registered in the same
city. A device's rules (stored by POST /api/device) decide whether it gets a
push: master switch, quiet hours (with an allow-list), incident types, saved
places (distance ≤ radius) and "near me" (last reported location ≤ 10 min old).
One push per (token, incident), recorded in alerts_sent with the reason.

APNs is spoken over HTTP/2 with token (JWT ES256) auth; the JWT is cached for
50 minutes. Env: APNS_KEY_PATH, APNS_KEY_ID, APNS_TEAM_ID, APNS_BUNDLE_ID,
APNS_SANDBOX (default for devices that don't say). APNS_URL_OVERRIDE points the
client at a stub for testing (tests/stub_apns.py).
"""
from __future__ import annotations

import json
import logging
import threading
import time
from datetime import datetime
from pathlib import Path

import config
import db
from geo import MILE_M, haversine_m

log = logging.getLogger(__name__)

APNS_HOST_PROD = "https://api.push.apple.com"
APNS_HOST_SANDBOX = "https://api.sandbox.push.apple.com"
JWT_TTL_SEC = 50 * 60
NEAR_ME_MAX_AGE_SEC = 600


# --- rule evaluation (pure) ----------------------------------------------------------------

def _hhmm(s: str | None) -> int | None:
    try:
        h, m = str(s).split(":")
        h, m = int(h), int(m)
        if 0 <= h < 24 and 0 <= m < 60:
            return h * 60 + m
    except (ValueError, AttributeError):
        pass
    return None


def quiet_active(quiet: dict | None, now: datetime) -> bool:
    """True while quiet hours cover `now` (local time). start == end means all day."""
    if not quiet or not quiet.get("enabled"):
        return False
    start, end = _hhmm(quiet.get("start")), _hhmm(quiet.get("end"))
    if start is None or end is None:
        return False
    cur = now.hour * 60 + now.minute
    if start == end:
        return True
    if start < end:
        return start <= cur < end
    return cur >= start or cur < end          # wraps midnight, e.g. 23:00 → 07:00


def _distance_mi(inc: dict, lat, lon) -> float | None:
    try:
        return haversine_m(float(inc["lat"]), float(inc["lon"]), float(lat), float(lon)) / MILE_M
    except (TypeError, ValueError, KeyError):
        return None


def match_reason(rules: dict | None, inc: dict, now_ts: float | None = None) -> str | None:
    """Why this incident should alert this device, or None. Reasons:
    "type:<incident_type>", "place:<name>", "near_me"."""
    if not rules or not rules.get("enabled"):
        return None
    now_ts = time.time() if now_ts is None else now_ts
    itype = (inc.get("incident_type") or "").lower()

    quiet = rules.get("quiet") or {}
    if quiet_active(quiet, datetime.fromtimestamp(now_ts, config.CITY_TZ)):
        allow = {str(t).lower() for t in (quiet.get("allow") or [])}
        if itype not in allow:
            return None

    if itype and itype in {str(t).lower() for t in (rules.get("types") or [])}:
        return f"type:{itype}"

    for p in rules.get("places") or []:
        if not p.get("enabled"):
            continue
        d = _distance_mi(inc, p.get("lat"), p.get("lon"))
        try:
            radius = float(p.get("radius_mi", 0.5))
        except (TypeError, ValueError):
            radius = 0.5
        if d is not None and d <= radius:
            return f"place:{p.get('name') or 'place'}"

    near = rules.get("near_me") or {}
    last = rules.get("last_location") or {}
    if near.get("enabled") and last:
        try:
            fresh = now_ts - float(last.get("at", 0)) <= NEAR_ME_MAX_AGE_SEC
            radius = float(near.get("radius_mi", 0.5))
        except (TypeError, ValueError):
            fresh, radius = False, 0.5
        d = _distance_mi(inc, last.get("lat"), last.get("lon"))
        if fresh and d is not None and d <= radius:
            return "near_me"
    return None


def _nearest_distance_mi(rules: dict, inc: dict, reason: str) -> float | None:
    """Distance to show in the title: from the matched place / the phone, else the
    nearest enabled place or a fresh phone location, else nothing."""
    if reason.startswith("place:"):
        name = reason[6:]
        for p in rules.get("places") or []:
            if p.get("name") == name:
                return _distance_mi(inc, p.get("lat"), p.get("lon"))
    last = rules.get("last_location") or {}
    if reason == "near_me" and last:
        return _distance_mi(inc, last.get("lat"), last.get("lon"))
    cands = []
    if last and time.time() - float(last.get("at", 0) or 0) <= NEAR_ME_MAX_AGE_SEC:
        d = _distance_mi(inc, last.get("lat"), last.get("lon"))
        if d is not None:
            cands.append(d)
    for p in rules.get("places") or []:
        if p.get("enabled"):
            d = _distance_mi(inc, p.get("lat"), p.get("lon"))
            if d is not None:
                cands.append(d)
    return min(cands) if cands else None


def _units_text(units) -> str:
    if isinstance(units, str):
        try:
            units = json.loads(units)
        except ValueError:
            units = {}
    names = sorted(units.keys()) if isinstance(units, dict) else list(units or [])
    return ", ".join(" ".join(w.capitalize() for w in u.split()) for u in names)


def payload_for(inc: dict, rules: dict, reason: str) -> dict:
    itype = inc.get("incident_type") or inc.get("summary") or "Incident"
    title = itype[:1].upper() + itype[1:]
    d = _nearest_distance_mi(rules, inc, reason)
    if d is not None:
        title += f" · {d:.1f} mi" if d < 10 else f" · {d:.0f} mi"
    address = inc.get("address") or "Unknown location"
    units = _units_text(inc.get("units"))
    body = f"{address} — {units}" if units else (f"{address} — {inc['summary']}" if inc.get("summary") else address)
    return {
        "aps": {
            "alert": {"title": title, "body": body},
            "sound": "default",
            "thread-id": inc.get("city") or config.CITY_ID,
        },
        "incident_id": inc["id"],
    }


# --- APNs client ----------------------------------------------------------------------------

class APNsClient:
    def __init__(self) -> None:
        self._jwt: str | None = None
        self._jwt_at = 0.0
        self._lock = threading.Lock()
        self._http = None

    @property
    def configured(self) -> bool:
        return bool(config.APNS_KEY_PATH and config.APNS_KEY_ID and config.APNS_TEAM_ID and config.APNS_BUNDLE_ID
                    and Path(config.APNS_KEY_PATH).exists())

    def _token(self) -> str:
        with self._lock:
            now = time.time()
            if self._jwt and now - self._jwt_at < JWT_TTL_SEC:
                return self._jwt
            import jwt as pyjwt

            key = Path(config.APNS_KEY_PATH).read_text()
            self._jwt = pyjwt.encode(
                {"iss": config.APNS_TEAM_ID, "iat": int(now)}, key, algorithm="ES256",
                headers={"kid": config.APNS_KEY_ID},
            )
            self._jwt_at = now
            return self._jwt

    def _client(self):
        if self._http is None:
            import httpx

            self._http = httpx.Client(http2=True, timeout=10.0)
        return self._http

    def send(self, device_token: str, payload: dict, sandbox: bool) -> tuple[int, str]:
        """POST one notification. Returns (status, body)."""
        host = config.APNS_URL_OVERRIDE or (APNS_HOST_SANDBOX if sandbox else APNS_HOST_PROD)
        auth = self._token() if self.configured else "unconfigured"
        headers = {
            "authorization": f"bearer {auth}",
            "apns-topic": config.APNS_BUNDLE_ID or "livewire",
            "apns-push-type": "alert",
            "apns-priority": "10",
            "apns-expiration": str(int(time.time()) + 3600),
            "content-type": "application/json",
        }
        r = self._client().post(f"{host}/3/device/{device_token}", headers=headers, content=json.dumps(payload))
        return r.status_code, r.text


client = APNsClient()
_warned_unconfigured = False


def _deliver(device: dict, inc: dict, reason: str) -> bool:
    global _warned_unconfigured
    if not client.configured and not config.APNS_URL_OVERRIDE:
        if not _warned_unconfigured:
            _warned_unconfigured = True
            log.warning("APNs not configured (APNS_KEY_PATH/KEY_ID/TEAM_ID/BUNDLE_ID); alerts are evaluated but not sent")
        return False
    rules = device["rules"]
    sandbox = bool(rules.get("sandbox", config.APNS_SANDBOX))
    payload = payload_for(inc, rules, reason)
    try:
        status, text = client.send(device["token"], payload, sandbox)
    except Exception as e:
        log.warning("APNs send failed for %s…: %s", device["token"][:8], e)
        return False
    if status == 200:
        log.info("push → %s… (%s): %s", device["token"][:8], reason, payload["aps"]["alert"]["title"])
        return True
    if status == 410 or (status == 400 and "BadDeviceToken" in text):
        log.info("APNs says %s… is gone (%s); removing device", device["token"][:8], text.strip()[:80])
        db.delete_device(device["token"])
        return False
    log.warning("APNs %s for %s…: %s", status, device["token"][:8], text.strip()[:200])
    return False


def evaluate(inc: dict, now_ts: float | None = None) -> list[tuple[str, str]]:
    """Alert every matching device in the incident's city. Returns [(token, reason)] sent."""
    sent: list[tuple[str, str]] = []
    now_ts = time.time() if now_ts is None else now_ts
    for dev in db.devices_in(inc.get("city") or config.CITY_ID):
        reason = match_reason(dev.get("rules") or {}, inc, now_ts)
        if not reason:
            continue
        if db.alert_already_sent(dev["token"], inc["id"]):
            continue
        if _deliver(dev, inc, reason):
            db.record_alert(dev["token"], inc["id"], reason)
            sent.append((dev["token"], reason))
    return sent


def on_incident_created(inc: dict) -> None:
    """incidents.on_created callback (runs in the ingest thread)."""
    try:
        evaluate(inc)
    except Exception:
        log.exception("alert evaluation failed for incident #%s", inc.get("id"))
