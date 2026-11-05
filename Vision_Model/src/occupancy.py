"""Independent temporal debouncing; only valid observations can establish vacancy."""

from __future__ import annotations

import math
from dataclasses import dataclass

from .config import OccupancyConfig
from .zones import ZONE_IDS


@dataclass
class _State:
    state: str = "unknown"
    count: int | None = None
    last_seen: float | None = None
    candidate: bool | None = None
    candidate_since: float = 0.0
    samples: int = 0


class OccupancyTracker:
    def __init__(self, config: OccupancyConfig):
        self.config = config
        self._zones = {key: _State() for key in ZONE_IDS}
        self.last_observation: float | None = None
        self._last_clock: float | None = None

    def _check_clock(self, now: float) -> None:
        if not math.isfinite(now) or (self._last_clock is not None and now < self._last_clock):
            raise ValueError("Occupancy requires a finite, nondecreasing monotonic clock")
        self._last_clock = now

    def invalidate(self) -> None:
        self._zones = {key: _State() for key in ZONE_IDS}
        self.last_observation = None

    def expire(self, now: float) -> None:
        self._check_clock(now)
        if (
            self.last_observation is not None
            and now - self.last_observation > self.config.stale_seconds
        ):
            self.invalidate()

    def update(self, counts: dict[str, int], now: float) -> None:
        if set(counts) != set(ZONE_IDS) or any(
            type(v) is not int or v < 0 for v in counts.values()
        ):
            raise ValueError("One nonnegative integer count is required for each quadrant")
        self.expire(now)
        self.last_observation = now
        for key, count in counts.items():
            zone = self._zones[key]
            zone.count = count
            present = count > 0
            if present:
                zone.last_seen = now
            if zone.candidate != present:
                zone.candidate = present
                zone.candidate_since = now
                zone.samples = 0
            zone.samples += 1
            seconds = self.config.enter_seconds if present else self.config.clear_seconds
            required = self.config.enter_hits if present else self.config.clear_misses
            if zone.samples >= required and now - zone.candidate_since >= seconds:
                zone.state = "occupied" if present else "vacant"

    def snapshot(self, now: float) -> dict[str, dict]:
        self.expire(now)
        return {
            key: {
                "state": zone.state,
                "person_count": zone.count,
                "last_seen_age_ms": None
                if zone.last_seen is None
                else round((now - zone.last_seen) * 1000),
            }
            for key, zone in self._zones.items()
        }
