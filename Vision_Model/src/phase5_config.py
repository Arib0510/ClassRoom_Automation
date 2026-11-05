"""Additive Phase 5 configuration. Existing production configuration is never rewritten."""

from __future__ import annotations

import hashlib
import json
import math
import re
from dataclasses import dataclass
from pathlib import Path

from .config import AppConfig, load_config, read_yaml
from .zones import ZONE_IDS

MODES = ("OBSERVE", "DRY_RUN", "LIVE_TEST", "LIVE_APPLIANCE")
PROTOCOL = "classroom-control-v1"  # Proposed adapter, NOT verified ESP32 firmware.


def number(value, name, low, high, integer=False):
    if (
        isinstance(value, bool)
        or not isinstance(value, (float, int))
        or not math.isfinite(value)
        or not low <= value <= high
        or (integer and type(value) is not int)
    ):
        raise ValueError(f"{name} must be {'integer' if integer else 'finite'} in [{low},{high}]")
    return value


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", value):
        raise ValueError("Identifiers need 1-64 letters/digits/underscore/hyphen")
    return value


def exact(document, keys, name):
    if not isinstance(document, dict) or set(document) != set(keys):
        raise ValueError(f"{name} requires exactly {sorted(keys)}")


def digest(path: Path) -> str:
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


@dataclass(frozen=True)
class Phase5Config:
    base: AppConfig
    path: Path
    data: dict
    fingerprint: str

    @property
    def mode(self):
        return self.data["mode"]

    def relative(self, value):
        return (self.path.parent / value).resolve() if value else None


def load_phase5(path: Path | str = "config/phase5.example.yaml") -> Phase5Config:
    path = Path(path).resolve()
    d = read_yaml(path)
    exact(
        d,
        (
            "schema_version",
            "base_config",
            "mode",
            "camera",
            "strategy",
            "resources",
            "mqtt",
            "controllers",
            "appliances",
            "commissioning",
            "authorization",
            "logging",
        ),
        "Phase 5 config",
    )
    if type(d["schema_version"]) is not int or d["schema_version"] != 1 or d["mode"] not in MODES:
        raise ValueError("Phase 5 requires schema_version 1 and a supported mode")
    base = load_config(path.parent / d["base_config"])
    detector = base.detector
    if (
        detector.sha256.lower()
        != "3438ee45f33153b1fe6c49e18bcd869ce7c94ef01c485d4eb027eaf8fc0db8ac"
        or (
            detector.input_width,
            detector.input_height,
            detector.input_dtype,
            detector.input_encoding,
        )
        != (300, 300, "uint8", "raw_uint8")
        or (
            detector.scores_output,
            detector.boxes_output,
            detector.count_output,
            detector.classes_output,
            detector.person_class_id,
        )
        != (0, 1, 2, 3, 0)
    ):
        raise ValueError(
            "Phase 5 requires the reviewed SSD identity, input encoding "
            "and explicit output/class mapping"
        )
    exact(d["camera"], ("id", "pose_id", "rotation", "restart_attempts"), "camera")
    identifier(d["camera"]["id"])
    identifier(d["camera"]["pose_id"])
    if type(d["camera"]["rotation"]) is not int or d["camera"]["rotation"] not in (0, 90, 180, 270):
        raise ValueError("rotation must be 0/90/180/270 degrees clockwise")
    number(d["camera"]["restart_attempts"], "restart_attempts", 0, 5, True)
    exact(d["strategy"], ("mode", "roi", "overlap", "nms_iou", "allow_multipass"), "strategy")
    from .crops import ROI, make_crops

    if d["strategy"]["mode"] not in ("single_pass", "left_right", "overlap", "roi"):
        raise ValueError("Unsupported strategy")
    roi = ROI(*d["strategy"]["roi"])
    make_crops((640, 480), "overlap", roi, d["strategy"]["overlap"])
    number(d["strategy"]["nms_iou"], "nms_iou", 0.01, 1)
    if type(d["strategy"]["allow_multipass"]) is not bool:
        raise ValueError("allow_multipass must be boolean")
    if d["strategy"]["mode"] in ("left_right", "overlap") and not d["strategy"]["allow_multipass"]:
        raise ValueError("Multipass requires explicit resource-test authorization")
    exact(
        d["resources"],
        (
            "inference_timeout_seconds",
            "startup_timeout_seconds",
            "max_pipeline_seconds",
            "max_total_rss_mb",
            "min_available_mb",
        ),
        "resources",
    )
    for key, value in d["resources"].items():
        number(value, key, 0.05, 1024 if key.endswith("mb") else 120)
    if d["resources"]["max_pipeline_seconds"] > base.occupancy.stale_seconds:
        raise ValueError("Pipeline budget must not exceed observation freshness")
    exact(
        d["mqtt"],
        (
            "enabled",
            "prefix",
            "command_qos",
            "lease_seconds",
            "ack_timeout_seconds",
            "status_timeout_seconds",
            "min_command_interval_seconds",
            "max_attempts",
        ),
        "mqtt",
    )
    if type(d["mqtt"]["enabled"]) is not bool:
        raise ValueError("MQTT enabled must be boolean")
    prefix = d["mqtt"]["prefix"]
    if (
        not isinstance(prefix, str)
        or not prefix
        or prefix.endswith("/")
        or any(c in prefix for c in ("#", "+", "\0", "\n", "\r"))
        or prefix == base.mqtt.topic_prefix
    ):
        raise ValueError("Phase 5 needs an exact separate topic prefix without wildcards")
    number(d["mqtt"]["command_qos"], "command_qos", 0, 1, True)
    for key in (
        "lease_seconds",
        "ack_timeout_seconds",
        "status_timeout_seconds",
        "min_command_interval_seconds",
    ):
        number(d["mqtt"][key], key, 0.05, 30)
    if d["mqtt"]["lease_seconds"] > base.occupancy.stale_seconds:
        raise ValueError("Command lease cannot exceed sensor freshness")
    number(d["mqtt"]["max_attempts"], "max_attempts", 1, 3, True)
    if not isinstance(d["controllers"], list) or len(d["controllers"]) > 8:
        raise ValueError("At most eight explicit controllers")
    controllers = {}
    for controller in d["controllers"]:
        exact(
            controller,
            (
                "id",
                "protocol",
                "firmware_sha256",
                "verified",
                "evidence",
                "dry_run_enforced",
                "local_fault_policy",
            ),
            "controller",
        )
        cid = identifier(controller["id"])
        if any(
            not isinstance(controller[k], str)
            for k in ("firmware_sha256", "evidence", "local_fault_policy")
        ):
            raise ValueError("Controller provenance fields must be strings")
        if cid in controllers or controller["protocol"] != PROTOCOL:
            raise ValueError("Duplicate controller or unsupported protocol adapter")
        for flag in ("verified", "dry_run_enforced"):
            if type(controller[flag]) is not bool:
                raise ValueError("Controller verification flags must be boolean")
        if controller["verified"] and (
            not re.fullmatch(r"[0-9a-f]{64}", controller["firmware_sha256"])
            or not controller["evidence"].strip()
            or not controller["local_fault_policy"].strip()
        ):
            raise ValueError("Verified firmware requires checksum, evidence and local fault policy")
        controllers[cid] = controller
    if not isinstance(d["appliances"], list) or len(d["appliances"]) > 64:
        raise ValueError("At most 64 configured appliances")
    seen, channels = set(), set()
    for appliance in d["appliances"]:
        exact(
            appliance,
            (
                "id",
                "zone",
                "controller",
                "channel",
                "ownership_verified",
                "test_output_isolated",
                "off_delay_seconds",
            ),
            "appliance",
        )
        aid = identifier(appliance["id"])
        channel = identifier(appliance["channel"])
        identifier(appliance["controller"])
        pair = (appliance["controller"], channel)
        if (
            aid in seen
            or pair in channels
            or appliance["zone"] not in ZONE_IDS
            or appliance["controller"] not in controllers
        ):
            raise ValueError("Invalid/duplicate appliance ownership or controller channel")
        for flag in ("ownership_verified", "test_output_isolated"):
            if type(appliance[flag]) is not bool:
                raise ValueError("Appliance verification flags must be boolean")
        number(appliance["off_delay_seconds"], "off_delay_seconds", 0, 3600)
        seen.add(aid)
        channels.add(pair)
    for key in ("commissioning", "authorization"):
        if d[key] is not None and (not isinstance(d[key], str) or not d[key]):
            raise ValueError(f"{key} must be null or a file path")
    exact(d["logging"], ("max_bytes", "backup_count"), "logging")
    number(d["logging"]["max_bytes"], "max_bytes", 4096, 50_000_000, True)
    number(d["logging"]["backup_count"], "backup_count", 1, 10, True)
    # Bind authorization to configuration content, independent of its disk location.
    fingerprint = hashlib.sha256(
        json.dumps(
            {"phase5": d, "base_sha256": digest(path.parent / d["base_config"])}, sort_keys=True
        ).encode()
    ).hexdigest()
    return Phase5Config(base, path, d, fingerprint)
