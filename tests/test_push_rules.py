"""Pure tests for push rule evaluation and payloads (no network, no DB).

    python tests/test_push_rules.py        # or: pytest tests/test_push_rules.py
"""
from __future__ import annotations

import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import config  # noqa: E402
from push import match_reason, payload_for, quiet_active  # noqa: E402

INC = {"id": 7, "city": "lincoln", "agency": "fire", "incident_type": "structure fire",
       "summary": "Structure fire, smoke showing", "address": "1621 N 33rd St",
       "lat": 40.8268, "lon": -96.69, "units": {"truck 8": "on_scene", "battalion 1": "en_route"}}
HOME = {"name": "Home", "lat": 40.8300, "lon": -96.6900, "radius_mi": 0.5, "enabled": True}   # ~0.22 mi away
FAR = {"name": "Work", "lat": 40.7500, "lon": -96.6100, "radius_mi": 0.5, "enabled": True}    # ~6.8 mi away


def _noon() -> float:
    return datetime(2026, 6, 1, 12, 0, tzinfo=config.CITY_TZ).timestamp()


def _night() -> float:
    return datetime(2026, 6, 1, 23, 30, tzinfo=config.CITY_TZ).timestamp()


def test_master_switch_and_types():
    assert match_reason({"enabled": False, "types": ["structure fire"]}, INC, _noon()) is None
    assert match_reason({"enabled": True, "types": ["structure fire"]}, INC, _noon()) == "type:structure fire"
    assert match_reason({"enabled": True, "types": ["Shooting"]}, INC, _noon()) is None
    assert match_reason(None, INC, _noon()) is None


def test_places():
    assert match_reason({"enabled": True, "places": [FAR]}, INC, _noon()) is None
    assert match_reason({"enabled": True, "places": [FAR, HOME]}, INC, _noon()) == "place:Home"
    off = dict(HOME, enabled=False)
    assert match_reason({"enabled": True, "places": [off]}, INC, _noon()) is None
    small = dict(HOME, radius_mi=0.1)
    assert match_reason({"enabled": True, "places": [small]}, INC, _noon()) is None


def test_near_me_requires_fresh_location():
    now = _noon()
    rules = {"enabled": True, "near_me": {"enabled": True, "radius_mi": 0.5},
             "last_location": {"lat": 40.8300, "lon": -96.6900, "at": now - 60}}
    assert match_reason(rules, INC, now) == "near_me"
    rules["last_location"]["at"] = now - 601
    assert match_reason(rules, INC, now) is None
    rules["last_location"]["at"] = now
    rules["near_me"]["enabled"] = False
    assert match_reason(rules, INC, now) is None


def test_quiet_hours():
    q = {"enabled": True, "start": "23:00", "end": "07:00", "allow": ["shooting"]}
    assert quiet_active(q, datetime(2026, 6, 1, 23, 30, tzinfo=config.CITY_TZ))
    assert quiet_active(q, datetime(2026, 6, 2, 6, 59, tzinfo=config.CITY_TZ))
    assert not quiet_active(q, datetime(2026, 6, 2, 7, 0, tzinfo=config.CITY_TZ))
    assert not quiet_active(q, datetime(2026, 6, 2, 12, 0, tzinfo=config.CITY_TZ))
    assert not quiet_active({"enabled": False, "start": "00:00", "end": "23:59"}, datetime(2026, 6, 2, 12, 0, tzinfo=config.CITY_TZ))
    rules = {"enabled": True, "types": ["structure fire", "shooting"], "quiet": q}
    assert match_reason(rules, INC, _night()) is None, "structure fire is silenced at night"
    assert match_reason(rules, INC, _noon()) == "type:structure fire"
    shooting = dict(INC, incident_type="shooting")
    assert match_reason(rules, shooting, _night()) == "type:shooting", "allow-list gets through quiet hours"


def test_payload():
    rules = {"enabled": True, "places": [HOME], "types": ["structure fire"]}
    p = payload_for(INC, rules, "type:structure fire")
    assert p["aps"]["alert"]["title"] == "Structure fire · 0.2 mi", p["aps"]["alert"]["title"]
    assert p["aps"]["alert"]["body"] == "1621 N 33rd St — Battalion 1, Truck 8"
    assert p["aps"]["sound"] == "default" and p["aps"]["thread-id"] == "lincoln" and p["incident_id"] == 7
    p2 = payload_for(INC, {"enabled": True, "types": ["structure fire"]}, "type:structure fire")
    assert p2["aps"]["alert"]["title"] == "Structure fire", "no distance without a place or location"
    p3 = payload_for(dict(INC, units="{}"), {"enabled": True}, "type:x")
    assert p3["aps"]["alert"]["body"] == "1621 N 33rd St — Structure fire, smoke showing"


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for t in tests:
        t()
        print("ok  ", t.__name__)
    print(f"{len(tests)} push rule tests passed")
