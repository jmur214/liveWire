"""Verify /api/stream against a running server while a replay is emitting.

    uvicorn server:app --port 8000 &
    python main.py --replay tests/fixtures/lincoln_day.json --speed 20 &
    API_TOKEN=dev-token python tests/check_stream.py [http://127.0.0.1:8000] [seconds]

Checks: `transmission` and `incident` events arrive (each within 1 s of the
replay storing the row), `ping` events arrive every ~15 s, and the stream is
refused without the token.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8000"
SECS = float(sys.argv[2]) if len(sys.argv) > 2 else 35
TOKEN = os.environ.get("API_TOKEN", "dev-token")

# auth
try:
    urllib.request.urlopen(urllib.request.Request(BASE + "/api/stream"), timeout=5)
    print("FAIL stream without token should be 401"); sys.exit(1)
except urllib.error.HTTPError as e:
    assert e.code == 401, e.code
    print("ok   stream refused without token")

# curl -N is exactly what B5 asks for; parse its output as SSE
cmd = ["curl", "-sN", "-H", f"Authorization: Bearer {TOKEN}", f"{BASE}/api/stream"]
proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, bufsize=0)
fd = proc.stdout.fileno()
t_end = time.time() + SECS
events: list[tuple[float, str, dict]] = []
buf = b""
import os as _os
import select
while time.time() < t_end:
    r, _, _ = select.select([fd], [], [], 0.2)
    if not r:
        continue
    chunk = _os.read(fd, 65536)
    if not chunk:
        break
    now = time.time()
    buf += chunk
    while b"\n\n" in buf:
        block, buf = buf.split(b"\n\n", 1)
        ev, data = None, None
        for line in block.decode().split("\n"):
            if line.startswith("event:"):
                ev = line[6:].strip()
            elif line.startswith("data:"):
                data = line[5:].strip()
        if ev:
            events.append((now, ev, json.loads(data or "{}")))
proc.kill()

kinds = {}
for _, k, _ in events:
    kinds[k] = kinds.get(k, 0) + 1
print("events:", kinds)
tx = [(t, d) for t, k, d in events if k == "transmission"]
inc = [(t, d) for t, k, d in events if k == "incident"]
pings = [t for t, k, _ in events if k == "ping"]
assert tx, "no transmission events"
assert inc, "no incident events"
lat = [t - d["heard_at"] for t, d in tx]
print(f"ok   {len(tx)} transmission events; latency min/median/max = {min(lat):.2f}/{sorted(lat)[len(lat)//2]:.2f}/{max(lat):.2f} s")
assert max(lat) < 1.0, "transmission event later than 1 s after storage"
print(f"ok   {len(inc)} incident events (create/update/clear)")
statuses = {d["status"] for _, d in inc}
print("     incident statuses seen:", statuses)
assert all(k in inc[0][1] for k in ("id", "agency", "lat", "lon", "units", "last_heard", "status", "tx_count")), inc[0][1].keys()
gaps = [b - a for a, b in zip(pings, pings[1:])]
print(f"ok   {len(pings)} pings" + (f"; gaps {[round(g,1) for g in gaps]}" if gaps else ""))
assert len(pings) >= int(SECS // 15), "expected a ping every 15 s"
assert all(14 <= g <= 16.5 for g in gaps), gaps
print("\nstream checks passed")
