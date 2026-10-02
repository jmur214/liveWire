"""Exercise every B3 endpoint against a running server after a replay of
tests/fixtures/lincoln_day.json. Exits non-zero on the first failed check.

    uvicorn server:app --port 8000 &
    python main.py --replay tests/fixtures/lincoln_day.json --speed 200
    API_TOKEN=dev-token python tests/check_api.py [http://127.0.0.1:8000]
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8000"
TOKEN = os.environ.get("API_TOKEN", "dev-token")
checks = 0


def req(path: str, *, token: str | None = TOKEN, method: str = "GET", body: dict | None = None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(BASE + path, data=data, method=method)
    if token:
        r.add_header("Authorization", f"Bearer {token}")
    if data is not None:
        r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r, timeout=10) as resp:
            ct = resp.headers.get("content-type", "")
            raw = resp.read()
            return resp.status, ct, (json.loads(raw) if "json" in ct else raw)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, e.headers.get("content-type", ""), json.loads(raw)
        except ValueError:
            return e.code, e.headers.get("content-type", ""), raw


def check(cond: bool, label: str, extra: str = "") -> None:
    global checks
    checks += 1
    print(f"{'ok  ' if cond else 'FAIL'} {label}{(' — ' + extra) if extra else ''}")
    if not cond:
        sys.exit(1)


# --- auth ---------------------------------------------------------------------------------
st, _, body = req("/api/health", token=None)
check(st == 401 and body.get("error") == "unauthorized", "no token -> 401 {error}")
st, _, _ = req("/api/health", token="wrong")
check(st == 401, "wrong token -> 401")
st, _, _ = req(f"/api/health?token={TOKEN}", token=None)
check(st == 200, "?token= accepted (for <audio> tags in the web map)")
st, _, _ = req("/", token=None)
check(st == 200, "/ (Leaflet map) served without a token")

# --- health / cities ----------------------------------------------------------------------
st, _, h = req("/api/health")
check(st == 200 and h["ok"] is True and h["city"] == "lincoln", "health ok", json.dumps(h))
check(h["police_delay_sec"] != 900, "police_delay_sec is non-default after the clock read", str(h["police_delay_sec"]))
check(h["last_transmission_at"] is not None, "last_transmission_at present")

st, _, c = req("/api/cities")
city = c["cities"][0]
check(st == 200 and city["id"] == "lincoln" and "structure fire" in city["incident_types"], "cities + incident_types")
check(city["agencies"]["police"]["delayed"] is True, "police flagged delayed in city config")

# --- incidents ----------------------------------------------------------------------------
st, _, inc = req("/api/incidents?hours=2")
incs = inc["incidents"]
check(st == 200 and 8 <= len(incs) <= 10, "8-10 incidents", f"{len(incs)}")
check(all(incs[i]["last_heard"] >= incs[i + 1]["last_heard"] for i in range(len(incs) - 1)), "sorted last_heard desc")
by_addr = {}
for i in incs:
    by_addr.setdefault(i["address"], []).append(i["id"])
check(len(by_addr["1621 N 33rd St"]) == 1, "same-address transmissions share one incident")
fire1 = next(i for i in incs if i["address"] == "1621 N 33rd St")
check(fire1["tx_count"] >= 7, "acknowledgements attached via unit names", f"tx_count={fire1['tx_count']}")
check(fire1["units"].get("engine 1") == "clear" and fire1["units"].get("truck 8") == "on_scene",
      "unit statuses from latest transcript", json.dumps(fire1["units"]))
check(fire1["delayed"] is False and fire1["delay_sec"] == 0, "fire not delayed")
pol = next(i for i in incs if i["agency"] == "police")
check(pol["delayed"] is True and pol["delay_sec"] == h["police_delay_sec"], "police delayed with estimator value")
check(fire1["location_kind"] == "address" and fire1["heard_as"] == "1621 North 33rd Street"
      and fire1["location_confidence"] == 0.92, "location_kind / heard_as / location_confidence from first mapped tx")
cleared = [i for i in incs if i["status"] == "cleared"]
check(len(cleared) >= 1, "some incidents cleared after 30 simulated idle min", f"{len(cleared)} cleared")

st, _, f = req("/api/incidents?hours=2&agencies=fire")
check(all(i["agency"] == "fire" for i in f["incidents"]) and len(f["incidents"]) == 4, "agency filter", f"{len(f['incidents'])} fire")

st, _, d = req(f"/api/incidents/{fire1['id']}")
check(st == 200 and len(d["transmissions"]) == fire1["tx_count"], "detail has all transmissions")
tl = d["transmissions"]
check(all(tl[i]["occurred_at"] >= tl[i + 1]["occurred_at"] for i in range(len(tl) - 1)), "timeline occurred_at desc")
check(all(k in tl[0] for k in ("id", "occurred_at", "heard_at", "transcript", "audio_file", "duration", "units", "summary")), "timeline row shape")
# statuses change across the timeline: Engine 1 went dispatched -> en_route -> clear
e1 = [t["transcript"] for t in reversed(tl) if "engine 1" in [u.lower() for u in t["units"]]]
check(len(e1) >= 3, "unit appears in several timeline rows", " | ".join(x[:25] for x in e1))

med = next(i for i in incs if i["incident_type"] == "medical")
check(med["units"] == {"engine 5": "clear", "medic 3": "dispatched"}, "medical unit statuses", json.dumps(med["units"]))

st, _, e = req("/api/incidents/999999")
check(st == 404 and "error" in e, "404 shape")
st, _, e = req("/api/incidents?hours=abc")
check(st == 422 and "error" in e, "422 shape")

# --- transmissions ------------------------------------------------------------------------
st, _, t = req("/api/transmissions?limit=200")
txs = t["transmissions"]
check(st == 200 and len(txs) == 64 and t["latest_id"] == txs[-1]["id"], "all 64 transmissions, latest_id", f"{len(txs)}")
check(all(txs[i]["id"] < txs[i + 1]["id"] for i in range(len(txs) - 1)), "id asc")
st, _, t2 = req(f"/api/transmissions?since_id={txs[-5]['id']}")
check(len(t2["transmissions"]) == 4, "since_id pages", f"{len(t2['transmissions'])}")
st, _, t3 = req(f"/api/transmissions?since_id={txs[-1]['id']}")
check(t3["transmissions"] == [] and t3["latest_id"] == txs[-1]["id"], "empty page keeps latest_id")
by_text = {x["transcript"]: x for x in txs}
check(by_text["Lincoln, radio check."]["incident_id"] is None, "noise stays ungrouped")
check(by_text["Lincoln, show Baker 14 back in service."]["incident_id"] is None, "unit of a cleared incident stays ungrouped")
check(by_text["Truck 8 responding."]["incident_id"] == fire1["id"], "ack joins via unit")
check(by_text["Medic 1 staged at 24th and Y."]["incident_id"] != by_text["Medic 1 responding."]["incident_id"],
      "unit re-used later joins the most recent active incident")
first = txs[0]
check(first["address"] == "1621 N 33rd St" and first["lat"] == 40.8268, "transmission address/lat")
check(all(k in first for k in ("id", "incident_id", "agency", "occurred_at", "heard_at", "transcript", "summary",
                                 "address", "lat", "lon", "audio_file", "duration", "units")), "transmission row shape")
pol_tx = next(x for x in txs if x["agency"] == "police")
check(pol_tx["heard_at"] - pol_tx["occurred_at"] > 600, "police occurred_at back-dated", f"{pol_tx['heard_at'] - pol_tx['occurred_at']:.0f}s")

# --- audio --------------------------------------------------------------------------------
st, ct, raw = req(f"/audio/{first['audio_file']}")
check(st == 200 and ct.startswith("audio/") and raw[:4] == b"RIFF", "audio clip served with token", ct)
st, _, _ = req(f"/audio/{first['audio_file']}", token=None)
check(st == 401, "audio clip refused without token")

# --- report -------------------------------------------------------------------------------
st, _, r = req("/api/report", method="POST", body={"incident_id": fire1["id"], "reason": "wrong_location"})
check(st == 200 and r["ok"] is True, "report ok")
st, _, d2 = req(f"/api/incidents/{fire1['id']}")
check(d2["reported_wrong"] is True, "reported_wrong persisted")

# --- legacy map endpoints -----------------------------------------------------------------
st, _, ev = req("/api/events?hours=2")
check(st == 200 and len(ev["events"]) == 15, "legacy /api/events (mapped transmissions)", f"{len(ev['events'])}")
st, _, tr = req("/api/transcript?hours=2")
check(st == 200 and len(tr["events"]) == 64, "legacy /api/transcript")

print(f"\nall {checks} checks passed")
