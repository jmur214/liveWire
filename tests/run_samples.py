"""Run extraction + geocoding over sample transcripts, no audio needed.

    ANTHROPIC_API_KEY=... python tests/run_samples.py
    python tests/run_samples.py --no-geocode     # extraction only
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from delay import DelayEstimator  # noqa: E402
from extract import extract  # noqa: E402
from geocode import geocode  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-geocode", action="store_true")
    args = ap.parse_args()

    samples = json.loads((Path(__file__).parent / "sample_transcripts.json").read_text())
    delays = DelayEstimator()
    failures = 0
    for s in samples:
        inc = extract(s["text"])
        delays.observe(s["text"], time.time(), inc.spoken_time)
        pt = geocode(inc.geocode_query, inc.location_kind) if (inc.mappable and not args.no_geocode) else None
        ok = inc.mappable == s["expect_mappable"] and (
            "expect_agency" not in s or inc.agency == s["expect_agency"]
        )
        failures += 0 if ok else 1
        print(f"{'OK ' if ok else 'BAD'} | {s['text'][:60]!r}")
        print(f"     agency={inc.agency} type={inc.incident_type} conf={inc.confidence:.2f}")
        print(f"     query={inc.geocode_query!r} kind={inc.location_kind} -> {pt}")
        print(f"     summary={inc.summary!r} units={inc.units} time={inc.spoken_time}")
    print(f"\n{len(samples) - failures}/{len(samples)} passed; police delay estimate {delays.police_delay:.0f}s")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
