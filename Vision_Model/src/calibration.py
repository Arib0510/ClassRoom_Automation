"""Versioned physical room geometry and conservative person-location assignment.

No detector, crop, camera, MQTT or appliance runtime is imported here.
"""

from __future__ import annotations

import copy
import hashlib
import json
import math
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

import yaml

from .calibration_geometry import fit_homography, inside_margin, point, polygon, project
from .zones import ZONE_IDS, Zone, _overlap

SCHEMA_VERSION = 2
CONFIRMATION_PHRASE = "CONFIRM MOUNTED CAMERA CALIBRATION"
CHECKS = (
    "mounted_frame",
    "zone_ownership",
    "anchors",
    "exclusions",
    "seat_regions",
    "floor_landmarks",
)


def timestamp() -> str:
    return datetime.now(UTC).isoformat()


def file_hash(path: Path) -> str:
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def geometry_digest(data: dict) -> str:
    content = copy.deepcopy(data)
    for key in ("calibrated", "confirmation", "revision"):
        content.pop(key, None)
    for key in ("created_at", "updated_at"):
        content.get("metadata", {}).pop(key, None)
    return hashlib.sha256(json.dumps(content, sort_keys=True, allow_nan=False).encode()).hexdigest()


def new_document(reference: dict) -> dict:
    """Create a draft with a floor-plan template, never image quadrant occupancy masks."""
    boundaries = (
        [[0, 0], [0.5, 0], [0.5, 0.5], [0, 0.5]],
        [[0.5, 0], [1, 0], [1, 0.5], [0.5, 0.5]],
        [[0, 0.5], [0.5, 0.5], [0.5, 1], [0, 1]],
        [[0.5, 0.5], [1, 0.5], [1, 1], [0.5, 1]],
    )
    return {
        "schema_version": SCHEMA_VERSION,
        "revision": 0,
        "calibrated": False,
        "metadata": {
            "title": "Classroom calibration draft",
            "created_at": timestamp(),
            "updated_at": timestamp(),
            "notes": "Floor-plan template requires on-site review",
        },
        "reference": reference,
        "assignment": {
            "method": "seat_regions",
            "anchor_fraction": [0.5, 0.25],
            "boundary_margin_px": 4.0,
            "ground_margin": 0.01,
        },
        "appliance_zones": [
            {"id": key, "floor_polygon": vertices, "image_polygon": []}
            for key, vertices in zip(ZONE_IDS, boundaries, strict=True)
        ],
        "seat_regions": [],
        "seating_rows": [],
        "excluded_regions": [],
        "floor_landmarks": [],
        "homography": {"max_reprojection_error_px": 3.0},
        "confirmation": {
            "reviewer": "",
            "confirmed_at": None,
            "geometry_digest": None,
            "checks": dict.fromkeys(CHECKS, False),
        },
    }


def _keys(data, keys, name):
    if not isinstance(data, dict) or set(data) != set(keys):
        raise ValueError(f"{name} requires exactly: {', '.join(keys)}")


def _number(value, name, low, high):
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(value)
        or not low <= value <= high
    ):
        raise ValueError(f"{name} must be finite in [{low},{high}]")


def _text(value, name, *, empty=False):
    if not isinstance(value, str) or (not empty and not value.strip()) or len(value) > 4000:
        raise ValueError(f"{name} needs {'an optional' if empty else 'a nonempty'} string")


@dataclass(frozen=True)
class GroundPoint:
    image_xy: tuple[float, float]
    provenance: str
    uncertainty_px: float = 0.0

    def __post_init__(self):
        point(self.image_xy, "ground point")
        if self.provenance not in ("manual_floor_contact", "external_floor_estimate"):
            raise ValueError("Ground point needs explicit floor-contact provenance")
        _number(self.uncertainty_px, "ground uncertainty_px", 0, 1000)


@dataclass(frozen=True)
class Assignment:
    status: str  # assigned / unknown / preview (draft candidate, never occupancy evidence)
    zone_id: str | None = None
    reason: str = ""
    image_anchor: tuple[float, float] | None = None
    floor_anchor: tuple[float, float] | None = None
    seat_id: str | None = None


@dataclass(frozen=True)
class ZoneObservation:
    counts: dict[str, int] | None
    assignments: tuple[Assignment, ...]


class PhysicalCalibration:
    schema_version = SCHEMA_VERSION

    def __init__(self, data: dict):
        self._data = copy.deepcopy(data)
        self.homography = None
        self.homography_error = "At least four verified floor landmarks are required"
        self._validate()

    def to_dict(self) -> dict:
        return copy.deepcopy(self._data)

    @property
    def calibrated(self) -> bool:
        return self._data["calibrated"]

    @property
    def reference_size(self) -> tuple[int, int]:
        r = self._data["reference"]
        return r["width"], r["height"]

    def _validate(self):
        data = self._data
        _keys(
            data,
            (
                "schema_version",
                "revision",
                "calibrated",
                "metadata",
                "reference",
                "assignment",
                "appliance_zones",
                "seat_regions",
                "seating_rows",
                "excluded_regions",
                "floor_landmarks",
                "homography",
                "confirmation",
            ),
            "calibration",
        )
        if type(data["schema_version"]) is not int or data["schema_version"] != SCHEMA_VERSION:
            raise ValueError("Unsupported calibration schema_version")
        if (
            type(data["revision"]) is not int
            or data["revision"] < 0
            or type(data["calibrated"]) is not bool
        ):
            raise ValueError("revision must be a nonnegative integer and calibrated a boolean")
        _keys(data["metadata"], ("title", "created_at", "updated_at", "notes"), "metadata")
        for key, value in data["metadata"].items():
            _text(value, key, empty=key == "notes")
        ref = data["reference"]
        _keys(
            ref,
            (
                "file_name",
                "sha256",
                "width",
                "height",
                "kind",
                "camera_id",
                "pose_id",
                "hflip",
                "vflip",
            ),
            "reference",
        )
        _text(ref["file_name"], "reference file_name")
        if (
            not isinstance(ref["sha256"], str)
            or len(ref["sha256"]) != 64
            or any(c not in "0123456789abcdef" for c in ref["sha256"])
        ):
            raise ValueError("reference requires a lowercase SHA256")
        if any(type(ref[k]) is not int or ref[k] <= 0 for k in ("width", "height")):
            raise ValueError("reference dimensions must be positive integers")
        if ref["kind"] not in ("illustrative", "mounted_pi"):
            raise ValueError("reference kind must be illustrative or mounted_pi")
        for key in ("camera_id", "pose_id"):
            _text(ref[key], key, empty=True)
        if any(type(ref[k]) is not bool for k in ("hflip", "vflip")):
            raise ValueError("reference flips must be booleans")
        settings = data["assignment"]
        _keys(
            settings,
            ("method", "anchor_fraction", "boundary_margin_px", "ground_margin"),
            "assignment",
        )
        if settings["method"] not in ("seat_regions", "ground_plane"):
            raise ValueError("assignment method must be seat_regions or ground_plane")
        point(settings["anchor_fraction"], "anchor_fraction")
        _number(settings["boundary_margin_px"], "boundary_margin_px", 0, 1000)
        _number(settings["ground_margin"], "ground_margin", 0, 0.25)
        zones = data["appliance_zones"]
        if not isinstance(zones, list) or len(zones) != 4:
            raise ValueError("Exactly four appliance zones are required")
        if {z.get("id") for z in zones} != set(ZONE_IDS):
            raise ValueError("Four unique physical appliance zone IDs are required")
        floor_zones = []
        for z in zones:
            _keys(z, ("id", "floor_polygon", "image_polygon"), "appliance zone")
            floor_zones.append(Zone(z["id"], polygon(z["floor_polygon"], "floor zone")))
            polygon(z["image_polygon"], "image zone outline", optional=True)
        if any(_overlap(a, b) for i, a in enumerate(floor_zones) for b in floor_zones[i + 1 :]):
            raise ValueError("Physical floor-zone interiors overlap")
        self.floor_zones = tuple(floor_zones)
        for key in ("seat_regions", "seating_rows", "excluded_regions", "floor_landmarks"):
            entries = data[key]
            if not isinstance(entries, list) or len(entries) > 512:
                raise ValueError(f"{key} requires a bounded list (maximum 512 entries)")
            ids = [entry.get("id") for entry in entries]
            if len(set(ids)) != len(ids):
                raise ValueError(f"Duplicate IDs in {key}")
            for identifier in ids:
                _text(identifier, f"{key} id")
        row_ids = {row["id"] for row in data["seating_rows"]}
        for row in data["seating_rows"]:
            _keys(row, ("id", "image_points", "notes"), "seating row")
            if not isinstance(row["image_points"], list) or not 2 <= len(row["image_points"]) <= 12:
                raise ValueError("Seating row needs 2-12 reference-image points")
            for p in row["image_points"]:
                point(p, "row point")
            _text(row["notes"], "row notes", empty=True)
        self.seats = []
        for seat in data["seat_regions"]:
            _keys(seat, ("id", "row_id", "zone_id", "polygon", "floor_point"), "seat region")
            if seat["zone_id"] not in ZONE_IDS or seat["row_id"] not in row_ids:
                raise ValueError("Seat requires a known row and an appliance zone")
            vertices = polygon(seat["polygon"], "seat region")
            self.seats.append((seat, vertices))
            if seat["floor_point"] is not None:
                fp = point(seat["floor_point"], "seat floor point")
                owner = next(z for z in self.floor_zones if z.id == seat["zone_id"])
                if not owner.contains(fp):
                    raise ValueError("Seat floor-plan marker is outside its mapped appliance zone")
        self.exclusions = []
        for exclusion in data["excluded_regions"]:
            _keys(exclusion, ("id", "polygon"), "excluded region")
            self.exclusions.append(polygon(exclusion["polygon"], "excluded region"))
        for landmark in data["floor_landmarks"]:
            _keys(landmark, ("id", "image", "floor", "on_floor"), "floor landmark")
            point(landmark["image"], "landmark image point")
            point(landmark["floor"], "landmark physical floor point")
            if type(landmark["on_floor"]) is not bool:
                raise ValueError("Landmark on_floor must be an explicit boolean")
        _keys(data["homography"], ("max_reprojection_error_px",), "homography")
        error = data["homography"]["max_reprojection_error_px"]
        _number(error, "max_reprojection_error_px", 0.01, 100)
        landmarks = data["floor_landmarks"]
        if len(landmarks) >= 4 and all(p["on_floor"] for p in landmarks):
            try:
                self.homography = fit_homography(
                    [p["image"] for p in landmarks],
                    [p["floor"] for p in landmarks],
                    self.reference_size,
                    error,
                )
                self.homography_error = ""
            except ValueError as exc:
                self.homography_error = str(exc)
        confirmation = data["confirmation"]
        _keys(
            confirmation, ("reviewer", "confirmed_at", "geometry_digest", "checks"), "confirmation"
        )
        _keys(confirmation["checks"], CHECKS, "manual checks")
        if any(type(v) is not bool for v in confirmation["checks"].values()):
            raise ValueError("Manual confirmation checks must be booleans")
        if self.calibrated:
            self.require_confirmable()
            _text(confirmation["reviewer"], "confirmation reviewer")
            try:
                confirmed_at = datetime.fromisoformat(confirmation["confirmed_at"])
                if confirmed_at.tzinfo is None:
                    raise ValueError("Timestamp must include a timezone")
            except (ValueError, TypeError) as exc:
                raise ValueError("Confirmation requires an ISO timestamp with timezone") from exc
            if confirmation["geometry_digest"] != geometry_digest(data):
                raise ValueError("Calibration changed since manual confirmation")

    def require_confirmable(self):
        data = self._data
        ref = data["reference"]
        if (
            ref["kind"] != "mounted_pi"
            or not ref["camera_id"].strip()
            or not ref["pose_id"].strip()
        ):
            raise ValueError(
                "Final confirmation requires a mounted Pi reference, camera ID and pose ID"
            )
        needed = {"mounted_frame", "zone_ownership", "anchors", "exclusions"}
        if data["assignment"]["method"] == "seat_regions":
            needed.add("seat_regions")
            if {seat["zone_id"] for seat, _ in self.seats} != set(ZONE_IDS):
                raise ValueError(
                    "Confirmed seat mode needs seat coverage for all four appliance zones"
                )
        else:
            needed.add("floor_landmarks")
            if self.homography is None:
                raise ValueError(f"Cannot confirm ground mode: {self.homography_error}")
        if not all(data["confirmation"]["checks"][key] for key in needed):
            raise ValueError("All applicable on-site manual checks must be confirmed")

    def verify_reference(self, path: Path):
        if file_hash(path) != self._data["reference"]["sha256"]:
            raise ValueError("Reference image hash mismatch; use its own calibration")

    def validate_camera(self, camera):
        ref = self._data["reference"]
        if (camera.width, camera.height) != self.reference_size or any(
            getattr(camera, key) != ref[key] for key in ("hflip", "vflip")
        ):
            raise ValueError("Camera size/flips differ from the calibrated mounted reference")

    def locate(
        self, box=None, *, ground_point: GroundPoint | None = None, frame_size=None, preview=False
    ) -> Assignment:
        if frame_size is not None and tuple(frame_size) != self.reference_size:
            return Assignment("unknown", reason="frame_size_mismatch")
        if not self.calibrated and not preview:
            return Assignment("unknown", reason="calibration_pending")
        settings = self._data["assignment"]
        floor_anchor = None
        seat_id = None
        if settings["method"] == "seat_regions":
            if (
                not isinstance(box, (tuple, list))
                or len(box) != 4
                or any(
                    isinstance(v, bool)
                    or not isinstance(v, (int, float))
                    or not math.isfinite(v)
                    or not 0 <= v <= 1
                    for v in box
                )
                or box[0] >= box[2]
                or box[1] >= box[3]
            ):
                return Assignment("unknown", reason="invalid_person_box")
            y0, x0, y1, x1 = box
            fx, fy = settings["anchor_fraction"]
            anchor = (x0 + fx * (x1 - x0), y0 + fy * (y1 - y0))
        else:
            if ground_point is None:
                return Assignment("unknown", reason="explicit_ground_contact_required")
            anchor = ground_point.image_xy
        if any(Zone("excluded", p).contains(anchor) for p in self.exclusions):
            return Assignment("unknown", reason="excluded_nonoccupancy_region", image_anchor=anchor)
        if settings["method"] == "seat_regions":
            hits = [
                (seat, vertices)
                for seat, vertices in self.seats
                if Zone(seat["id"], vertices).contains(anchor)
            ]
            if len(hits) != 1:
                return Assignment(
                    "unknown",
                    reason="no_seat_region" if not hits else "ambiguous_seat_regions",
                    image_anchor=anchor,
                )
            seat, vertices = hits[0]
            if not inside_margin(
                anchor, vertices, settings["boundary_margin_px"], self.reference_size
            ):
                return Assignment("unknown", reason="seat_boundary_uncertain", image_anchor=anchor)
            owner, seat_id = seat["zone_id"], seat["id"]
            floor_anchor = tuple(seat["floor_point"]) if seat["floor_point"] is not None else None
        else:
            h = self.homography
            if h is None:
                return Assignment("unknown", reason="homography_unavailable", image_anchor=anchor)
            margin = settings["boundary_margin_px"] + ground_point.uncertainty_px
            if not inside_margin(anchor, h["image_hull"], margin, self.reference_size):
                return Assignment(
                    "unknown", reason="outside_floor_reference_domain", image_anchor=anchor
                )
            floor_anchor = project(h["matrix"], anchor)
            hits = [z for z in self.floor_zones if z.contains(floor_anchor)]
            if len(hits) != 1 or not inside_margin(
                floor_anchor, hits[0].polygon, settings["ground_margin"]
            ):
                return Assignment(
                    "unknown",
                    reason="ground_zone_boundary_or_outside",
                    image_anchor=anchor,
                    floor_anchor=floor_anchor,
                )
            # Map an uncertainty square as well: it must stay entirely inside one physical zone.
            dx, dy = margin / self.reference_size[0], margin / self.reference_size[1]
            for offset in ((-dx, -dy), (-dx, dy), (dx, -dy), (dx, dy)):
                p = (anchor[0] + offset[0], anchor[1] + offset[1])
                if not Zone("reference domain", h["image_hull"]).contains(p):
                    return Assignment(
                        "unknown",
                        reason="ground_uncertainty_leaves_reference_domain",
                        image_anchor=anchor,
                        floor_anchor=floor_anchor,
                    )
                q = project(h["matrix"], p)
                if not inside_margin(q, hits[0].polygon, settings["ground_margin"]):
                    return Assignment(
                        "unknown",
                        reason="ground_uncertainty_crosses_boundary",
                        image_anchor=anchor,
                        floor_anchor=floor_anchor,
                    )
            owner = hits[0].id
        return Assignment(
            "assigned" if self.calibrated else "preview",
            owner,
            "manually_calibrated_geometry" if self.calibrated else "draft_candidate_only",
            anchor,
            floor_anchor,
            seat_id,
        )

    def assign(self, box) -> str | None:
        result = self.locate(box)
        return result.zone_id if result.status == "assigned" else None

    def observe(self, boxes, *, frame_size) -> ZoneObservation:
        assignments = tuple(self.locate(box, frame_size=frame_size) for box in boxes)
        if (
            not self.calibrated
            or tuple(frame_size) != self.reference_size
            or any(a.status != "assigned" for a in assignments)
        ):
            return ZoneObservation(None, assignments)
        counts = dict.fromkeys(ZONE_IDS, 0)
        for a in assignments:
            counts[a.zone_id] += 1
        return ZoneObservation(counts, assignments)

    def count(self, boxes) -> dict[str, int]:
        observation = self.observe(boxes, frame_size=self.reference_size)
        if observation.counts is None:
            raise ValueError("UNKNOWN location must not be converted into zero occupancy counts")
        return observation.counts


def confirm_document(data: dict, *, reviewer: str, phrase: str, preview_digest: str) -> dict:
    draft = copy.deepcopy(data)
    if phrase != CONFIRMATION_PHRASE or preview_digest != geometry_digest(draft):
        raise ValueError(
            "Explicit confirmation and a current preview of this geometry are required"
        )
    _text(reviewer, "reviewer")
    PhysicalCalibration(draft).require_confirmable()
    draft["calibrated"] = True
    draft["confirmation"].update(
        reviewer=reviewer, confirmed_at=timestamp(), geometry_digest=geometry_digest(draft)
    )
    PhysicalCalibration(draft)
    return draft


class CalibrationSession:
    """Validated drafts, bounded undo, atomic versioned save and content-addressed backups."""

    def __init__(self, data: dict):
        PhysicalCalibration(data)
        self.data = copy.deepcopy(data)
        self.history: list[dict] = []
        self.previewed_digest: str | None = None

    def replace(self, data: dict):
        draft = copy.deepcopy(data)
        draft["revision"] = self.data["revision"]
        draft["calibrated"] = False
        draft["confirmation"] = new_document(draft["reference"])["confirmation"]
        PhysicalCalibration(draft)
        self.history.append(copy.deepcopy(self.data))
        self.history = self.history[-30:]
        self.data = draft
        self.previewed_digest = None

    def undo(self):
        if self.history:
            restored = self.history.pop()
            # Undo restores geometry, never silently restores deployment approval.
            restored["calibrated"] = False
            restored["revision"] = self.data["revision"]
            restored["confirmation"] = new_document(restored["reference"])["confirmation"]
            self.data = restored
            self.previewed_digest = None

    def mark_previewed(self):
        self.previewed_digest = geometry_digest(self.data)

    def confirm(self, reviewer: str, phrase: str, checks: dict):
        draft = copy.deepcopy(self.data)
        draft["confirmation"]["checks"] = checks
        self.data = confirm_document(
            draft, reviewer=reviewer, phrase=phrase, preview_digest=self.previewed_digest
        )

    def save(self, path: Path):
        PhysicalCalibration(self.data)
        if path.suffix.lower() not in (".yaml", ".yml", ".json"):
            raise ValueError("Calibration files must be versioned YAML or JSON")
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists():
            backup_dir = path.parent / f"{path.name}.backups"
            backup_dir.mkdir(exist_ok=True)
            old = path.read_bytes()
            backup = backup_dir / f"{hashlib.sha256(old).hexdigest()}{path.suffix}"
            if not backup.exists():
                backup.write_bytes(old)
        saved = copy.deepcopy(self.data)
        saved["revision"] += 1
        saved["metadata"]["updated_at"] = timestamp()
        text = (
            json.dumps(saved, indent=2, allow_nan=False) + "\n"
            if path.suffix.lower() == ".json"
            else yaml.safe_dump(saved, sort_keys=False, allow_unicode=True)
        )
        temporary = path.with_suffix(path.suffix + ".part")
        temporary.write_text(text, encoding="utf-8")
        temporary.replace(path)
        self.data = saved


def load_calibration(path: Path) -> PhysicalCalibration:
    with path.open(encoding="utf-8") as handle:
        data = json.load(handle) if path.suffix.lower() == ".json" else yaml.safe_load(handle)
    return PhysicalCalibration(data)
