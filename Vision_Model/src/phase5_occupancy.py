"""Physical mapping, explicit coverage and per-zone temporal evidence; no networking."""

from __future__ import annotations

import json
import math
from collections import deque
from dataclasses import dataclass
from datetime import datetime

from .calibration import load_calibration
from .config import OccupancyConfig
from .phase5_config import Phase5Config, digest, exact
from .zones import ZONE_IDS

STATES = ("OCCUPIED", "VACANT", "UNKNOWN")


def commissioning_template(config, geometry_path):
    """Bind a draft to geometry bytes; never assert physical verification automatically."""
    geometry = load_calibration(geometry_path)
    camera = config.data["camera"]
    width, height = config.base.camera.width, config.base.camera.height
    if camera["rotation"] in (90, 270):
        width, height = height, width
    return {
        "schema_version": 1,
        "calibration_file": str(geometry_path.resolve()),
        "calibration_sha256": digest(geometry_path),
        "calibration_version": geometry.to_dict()["revision"],
        "verified": False,
        "reviewer": "",
        "verified_at": None,
        "evidence": "",
        "camera": {
            "id": camera["id"],
            "pose_id": camera["pose_id"],
            "rotation": camera["rotation"],
            "width": width,
            "height": height,
            "hflip": config.base.camera.hflip,
            "vflip": config.base.camera.vflip,
        },
        "vacancy_coverage_verified": dict.fromkeys(ZONE_IDS, False),
    }


@dataclass(frozen=True)
class ZoneEvidence:
    state: str
    count: int | None
    confidence: float | None
    reason: str


def unknown(reason: str) -> dict[str, ZoneEvidence]:
    return {z: ZoneEvidence("UNKNOWN", None, None, reason) for z in ZONE_IDS}


class PhysicalMapper:
    def __init__(self, config: Phase5Config):
        self.config = config
        self.calibration = None
        self.document = None
        self.reason = "physical_commissioning_pending"
        path = config.relative(config.data["commissioning"])
        if path is None:
            return
        data = json.loads(path.read_text(encoding="utf-8"))
        exact(
            data,
            (
                "schema_version",
                "calibration_file",
                "calibration_sha256",
                "calibration_version",
                "verified",
                "reviewer",
                "verified_at",
                "evidence",
                "camera",
                "vacancy_coverage_verified",
            ),
            "commissioning",
        )
        if data["schema_version"] != 1 or type(data["verified"]) is not bool:
            raise ValueError("Invalid commissioning version/verification")
        coverage = data["vacancy_coverage_verified"]
        if set(coverage) != set(ZONE_IDS) or any(type(v) is not bool for v in coverage.values()):
            raise ValueError("Vacancy coverage needs four explicitly reviewed booleans")
        geometry_path = (path.parent / data["calibration_file"]).resolve()
        if digest(geometry_path) != data["calibration_sha256"]:
            raise ValueError("Commissioning calibration checksum mismatch")
        calibration = load_calibration(geometry_path)
        c = config.data["camera"]
        width, height = config.base.camera.width, config.base.camera.height
        if c["rotation"] in (90, 270):
            width, height = height, width
        expected = {
            "id": c["id"],
            "pose_id": c["pose_id"],
            "rotation": c["rotation"],
            "width": width,
            "height": height,
            "hflip": config.base.camera.hflip,
            "vflip": config.base.camera.vflip,
        }
        if data["camera"] != expected:
            raise ValueError("Commissioning camera identity/pose/orientation/dimensions mismatch")
        reference = calibration.to_dict()["reference"]
        if (
            reference["camera_id"] != c["id"]
            or reference["pose_id"] != c["pose_id"]
            or calibration.reference_size != (width, height)
            or reference["hflip"] != expected["hflip"]
            or reference["vflip"] != expected["vflip"]
        ):
            raise ValueError("Geometry reference does not match commissioned camera")
        if data["calibration_version"] != calibration.to_dict()["revision"]:
            raise ValueError("Commissioning revision mismatch")
        self.document = data
        self.geometry_path, self.path = geometry_path, path
        if not data["verified"]:
            return
        if (
            not calibration.calibrated
            or not data["reviewer"].strip()
            or not data["evidence"].strip()
        ):
            raise ValueError(
                "Verified commissioning requires confirmed mounted geometry and evidence"
            )
        when = datetime.fromisoformat(data["verified_at"])
        if when.tzinfo is None:
            raise ValueError("Commissioning time needs timezone")
        self.calibration = calibration
        self.reason = "verified_physical_mapping"
        self.commissioning_hash = digest(path)

    @property
    def ready(self):
        return self.calibration is not None

    def unchanged(self):
        try:
            return (
                self.ready
                and digest(self.geometry_path) == self.document["calibration_sha256"]
                and digest(self.path) == self.commissioning_hash
            )
        except OSError:
            return False

    def map(self, detections, size, *, image_usable=True):
        if not self.ready:
            return unknown(self.reason)
        if not self.unchanged():
            return unknown("calibration_changed")
        if tuple(size) != self.calibration.reference_size or not image_usable:
            return unknown("frame_geometry_or_visibility_invalid")
        scores = {z: [] for z in ZONE_IDS}
        for detection in detections:
            assignment = self.calibration.locate(detection.box, frame_size=size)
            if assignment.status != "assigned":
                # An unlocatable person must never disappear into a zero count.
                return unknown("unresolved_person:" + assignment.reason)
            scores[assignment.zone_id].append(detection.score)
        return {
            z: (
                ZoneEvidence("OCCUPIED", len(scores[z]), max(scores[z]), "mapped_person")
                if scores[z]
                else (
                    ZoneEvidence("VACANT", 0, None, "no_person_with_verified_coverage")
                    if self.document["vacancy_coverage_verified"][z]
                    else ZoneEvidence("UNKNOWN", None, None, "vacancy_coverage_unverified")
                )
            )
            for z in ZONE_IDS
        }


class TemporalOccupancy:
    """Same clock and debounce defaults as production, with per-zone UNKNOWN and frame dedupe."""

    def __init__(self, config: OccupancyConfig):
        self.config = config
        self.now = -math.inf
        self.last_capture = -math.inf
        self.seen = deque(maxlen=64)
        self.zones = {}
        self.invalidate("startup")

    def clock(self, now):
        if not math.isfinite(now) or now < self.now:
            raise ValueError("A finite nondecreasing monotonic clock is required")
        self.now = now

    def invalidate(self, reason):
        self.zones = {
            z: {
                "state": "UNKNOWN",
                "reason": reason,
                "count": None,
                "confidence": None,
                "candidate": None,
                "candidate_since": None,
                "hits": 0,
                "observed_at": None,
                "transition_at": None,
            }
            for z in ZONE_IDS
        }

    def expire(self, now):
        self.clock(now)
        for z, state in self.zones.items():
            if (
                state["observed_at"] is not None
                and now - state["observed_at"] >= self.config.stale_seconds
            ):
                self.zones[z] = {
                    **state,
                    "state": "UNKNOWN",
                    "reason": "stale_observation",
                    "candidate": None,
                    "hits": 0,
                    "count": None,
                    "confidence": None,
                    "observed_at": None,
                    "transition_at": now,
                }

    def update(self, frame_id, captured_at, evidence, now):
        self.expire(now)
        if not isinstance(frame_id, str) or not frame_id or set(evidence) != set(ZONE_IDS):
            raise ValueError("Unique frame ID and all four zones required")
        if not math.isfinite(captured_at) or captured_at > now:
            raise ValueError("Invalid capture timestamp")
        for item in evidence.values():
            if not isinstance(item, ZoneEvidence) or item.state not in STATES:
                raise ValueError("Invalid zone evidence")
            if (
                item.state == "OCCUPIED"
                and (type(item.count) is not int or item.count < 1)
                or item.state == "VACANT"
                and item.count != 0
                or item.confidence is not None
                and (not math.isfinite(item.confidence) or not 0 <= item.confidence <= 1)
            ):
                raise ValueError("Invalid evidence count/confidence")
        if frame_id in self.seen or captured_at <= self.last_capture:
            return False
        self.seen.append(frame_id)
        self.last_capture = captured_at
        if now - captured_at >= self.config.stale_seconds:
            self.invalidate("stale_frame")
            return False
        for z, item in evidence.items():
            state = self.zones[z]
            if item.state == "UNKNOWN":
                state.update(
                    state="UNKNOWN",
                    reason=item.reason,
                    count=None,
                    confidence=None,
                    candidate=None,
                    hits=0,
                    observed_at=None,
                    transition_at=now,
                )
                continue
            state.update(
                count=item.count,
                confidence=item.confidence,
                reason=item.reason,
                observed_at=captured_at,
            )
            if state["candidate"] != item.state:
                state.update(candidate=item.state, candidate_since=captured_at, hits=0)
            state["hits"] += 1
            seconds = (
                self.config.enter_seconds if item.state == "OCCUPIED" else self.config.clear_seconds
            )
            hits = self.config.enter_hits if item.state == "OCCUPIED" else self.config.clear_misses
            # Debounce is based on distinct capture times, never processing wall time.
            if state["hits"] >= hits and captured_at - state["candidate_since"] >= seconds:
                if state["state"] != item.state:
                    state["transition_at"] = now
                state["state"] = item.state
        return True

    def snapshot(self, now):
        self.expire(now)
        return {
            z: dict(
                s,
                observation_age_seconds=None
                if s["observed_at"] is None
                else now - s["observed_at"],
                confirmation_seconds=None
                if s["transition_at"] is None or s["candidate_since"] is None
                else s["transition_at"] - s["candidate_since"],
            )
            for z, s in self.zones.items()
        }
