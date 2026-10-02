"""Small geodesy helpers shared by grouping, alerts and the API."""
from __future__ import annotations

import math

EARTH_R_M = 6_371_008.8
MILE_M = 1609.344


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Great-circle distance in metres."""
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = p2 - p1
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * EARTH_R_M * math.asin(math.sqrt(a))


def miles(m: float) -> float:
    return m / MILE_M
