"""Convex room polygons in normalized, oriented camera coordinates."""

from __future__ import annotations

import math
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING

from .config import read_yaml

if TYPE_CHECKING:
    from .calibration import PhysicalCalibration

ZONE_IDS = ("front_left", "front_right", "back_left", "back_right")
EPSILON = 1e-9
Point = tuple[float, float]


def _cross(a: Point, b: Point, c: Point) -> float:
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])


@dataclass(frozen=True)
class Zone:
    id: str
    polygon: tuple[Point, ...]

    def contains(self, point: Point) -> bool:
        if not all(math.isfinite(v) for v in point):
            return False
        crosses = [
            _cross(a, b, point)
            for a, b in zip(self.polygon, self.polygon[1:] + self.polygon[:1], strict=True)
        ]
        return all(c >= -EPSILON for c in crosses) or all(c <= EPSILON for c in crosses)


def _overlap(a: Zone, b: Zone) -> bool:
    """Separating axis theorem: shared boundaries have no interior overlap."""
    for polygon in (a.polygon, b.polygon):
        for start, end in zip(polygon, polygon[1:] + polygon[:1], strict=True):
            axis = (-(end[1] - start[1]), end[0] - start[0])
            pa = [p[0] * axis[0] + p[1] * axis[1] for p in a.polygon]
            pb = [p[0] * axis[0] + p[1] * axis[1] for p in b.polygon]
            if min(max(pa), max(pb)) - max(min(pa), min(pb)) <= EPSILON:
                return False
    return True


@dataclass(frozen=True)
class ZoneMap:
    zones: tuple[Zone, ...]
    anchor: str
    calibrated: bool

    @classmethod
    def load(cls, path: Path) -> ZoneMap | PhysicalCalibration:
        data = read_yaml(path)
        if "schema_version" in data:
            from .calibration import PhysicalCalibration

            return PhysicalCalibration(data)
        if set(data) != {"zones", "anchor", "calibrated"}:
            raise ValueError("Zone file requires exactly zones, anchor and calibrated")
        if data["anchor"] not in ("bottom_center", "center"):
            raise ValueError("anchor must be bottom_center or center")
        if not isinstance(data["calibrated"], bool):
            raise ValueError("calibrated must be a YAML boolean")
        if not isinstance(data["zones"], list) or len(data["zones"]) != 4:
            raise ValueError("Exactly four physical quadrant polygons are required")
        zones = []
        for entry in data["zones"]:
            if not isinstance(entry, dict) or set(entry) != {"id", "polygon"}:
                raise ValueError("Each zone needs id and polygon")
            if not isinstance(entry["id"], str) or entry["id"] not in ZONE_IDS:
                raise ValueError("Unknown physical quadrant ID")
            polygon = entry["polygon"]
            if not isinstance(polygon, list) or not 3 <= len(polygon) <= 12:
                raise ValueError("Zone polygon needs 3-12 convex vertices")
            points = []
            for point in polygon:
                if (
                    not isinstance(point, list)
                    or len(point) != 2
                    or any(
                        isinstance(v, bool)
                        or not isinstance(v, (int, float))
                        or not math.isfinite(v)
                        or not 0 <= v <= 1
                        for v in point
                    )
                ):
                    raise ValueError("Each zone vertex needs finite normalized [x,y]")
                points.append(tuple(map(float, point)))
            p = tuple(points)
            turns = [_cross(p[i], p[(i + 1) % len(p)], p[(i + 2) % len(p)]) for i in range(len(p))]
            if not (all(t > EPSILON for t in turns) or all(t < -EPSILON for t in turns)):
                raise ValueError("Polygons must be strictly convex with ordered, unique vertices")
            # Checking every edge against every vertex also excludes self-intersecting stars.
            for i in range(len(p)):
                side = [_cross(p[i], p[(i + 1) % len(p)], vertex) for vertex in p]
                if any(v > EPSILON for v in side) and any(v < -EPSILON for v in side):
                    raise ValueError("Self-intersecting zone polygon")
            zones.append(Zone(entry["id"], p))
        if {z.id for z in zones} != set(ZONE_IDS):
            raise ValueError(f"Zone IDs must be {ZONE_IDS}")
        for i, zone in enumerate(zones):
            if any(_overlap(zone, other) for other in zones[i + 1 :]):
                raise ValueError("Zone polygon interiors overlap")
        # A fixed priority makes shared edges deterministic regardless of YAML ordering.
        ordered = tuple(next(z for z in zones if z.id == key) for key in ZONE_IDS)
        return cls(ordered, data["anchor"], data["calibrated"])

    def assign(self, box: tuple[float, float, float, float]) -> str | None:
        """Box is normalized (ymin,xmin,ymax,xmax); at most one zone per person."""
        ymin, xmin, ymax, xmax = box
        if not all(math.isfinite(v) and 0 <= v <= 1 for v in box) or ymin >= ymax or xmin >= xmax:
            return None
        point = ((xmin + xmax) / 2, ymax if self.anchor == "bottom_center" else (ymin + ymax) / 2)
        return next((z.id for z in self.zones if z.contains(point)), None)

    def count(self, boxes: list[tuple[float, float, float, float]]) -> dict[str, int]:
        counts = dict.fromkeys(ZONE_IDS, 0)
        for box in boxes:
            zone = self.assign(box)
            if zone is not None:
                counts[zone] += 1
        return counts
