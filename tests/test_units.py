"""Pure unit tests for the grouping helpers and type normaliser (no DB, no network).

    python tests/test_units.py        # or: pytest tests/test_units.py
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from extract import INCIDENT_TYPES, normalize_type  # noqa: E402
from geo import haversine_m, miles  # noqa: E402
from incidents import normalize_unit, short_address, unit_status  # noqa: E402


def test_unit_status_order():
    assert unit_status("Engine 1 clear, available.") == "clear"
    assert unit_status("Truck 8 on scene, smoke showing") == "on_scene"
    assert unit_status("Baker 12, ten-ninety-seven") == "on_scene"
    assert unit_status("David 22, 10-97.") == "on_scene"
    assert unit_status("Lancaster 7, ten-seventy-six.") == "en_route"
    assert unit_status("Adam 22, responding.") == "en_route"
    assert unit_status("Medic 3 en route") == "en_route"
    assert unit_status("Charlie 4, copy.") == "dispatched"
    # "clear" wins over "on scene" when both appear (A4 order)
    assert unit_status("Engine 3 on scene, now clear and back in service") == "clear"


def test_normalize_unit():
    assert normalize_unit("Engine  1,") == "engine 1"
    assert normalize_unit(" Battalion 1 ") == "battalion 1"
    assert normalize_unit("Lancaster-14") == "lancaster14"  # hyphen dropped consistently
    assert normalize_unit("engine_1") == "engine 1"           # never an underscore (snake-case decoders would mangle it)


def test_short_address():
    assert short_address("1621 N 33rd St, Lincoln, NE", "Lincoln, NE") == "1621 N 33rd St"
    assert short_address("Casey's, Cornhusker Hwy, Lincoln, NE", "Lincoln, NE") == "Casey's, Cornhusker Hwy"
    assert short_address("N 27th St & Vine St, Lincoln, Nebraska", "Lincoln, NE") == "N 27th St & Vine St"
    assert short_address(None, "Lincoln, NE") is None
    assert short_address("Lincoln, NE", "Lincoln, NE") == "Lincoln, NE"  # never empty


def test_normalize_type():
    for t in INCIDENT_TYPES:
        assert normalize_type(t) == t
    assert normalize_type(None) is None
    assert normalize_type("Structure Fire") == "structure fire"
    assert normalize_type("traffic_stop") == "traffic stop"
    assert normalize_type("accident with injuries") == "injury accident"
    assert normalize_type("non-injury accident") == "non-injury accident"
    assert normalize_type("shots fired") == "shooting"
    assert normalize_type("fight") == "disturbance"
    assert normalize_type("completely unknown thing") == "other"


def test_haversine():
    # 1621 N 33rd vs N 27th & Vine: ~700 m apart, not a 150 m join
    d = haversine_m(40.8268, -96.6900, 40.8208, -96.6868)
    assert 600 < d < 800
    # 22nd & Y vs 23rd & Y: ~100 m, joins
    assert haversine_m(40.8206, -96.6937, 40.8206, -96.6925) < 150
    assert abs(miles(1609.344) - 1.0) < 1e-9


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for t in tests:
        t()
        print("ok  ", t.__name__)
    print(f"{len(tests)} unit tests passed")
