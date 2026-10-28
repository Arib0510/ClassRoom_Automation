"""Typed configuration with early errors, safe YAML, and explicit path resolution."""

from __future__ import annotations

import math
import re
from dataclasses import dataclass, fields
from pathlib import Path
from typing import Any, TypeVar

import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]
T = TypeVar("T")


@dataclass(frozen=True)
class CameraConfig:
    width: int = 640
    height: int = 480
    fps: float = 5.0
    hflip: bool = False
    vflip: bool = False
    timeout_seconds: float = 3.0


@dataclass(frozen=True)
class DetectorConfig:
    model_path: Path
    labels_path: Path
    sha256: str
    input_encoding: str = "raw_uint8"
    input_dtype: str = "uint8"
    input_width: int = 300
    input_height: int = 300
    input_mean: float = 127.5
    input_std: float = 127.5
    input_scale: float = 0.007843137718737125
    input_zero_point: int = 127
    boxes_output: int = 1
    classes_output: int = 3
    scores_output: int = 0
    count_output: int = 2
    person_class_id: int = 0
    confidence_threshold: float = 0.55
    num_threads: int = 2


@dataclass(frozen=True)
class OccupancyConfig:
    enter_seconds: float = 0.5
    enter_hits: int = 2
    clear_seconds: float = 10.0
    clear_misses: int = 3
    stale_seconds: float = 4.0


@dataclass(frozen=True)
class MQTTConfig:
    host: str = "192.168.1.10"
    port: int = 1883
    client_id: str = "classroom-01-vision"
    topic_prefix: str = "classroom/classroom-01/vision"
    keepalive: int = 10
    heartbeat_seconds: float = 2.0
    expiry_seconds: int = 8
    username_env: str = "CLASSROOM_MQTT_USERNAME"
    password_env: str = "CLASSROOM_MQTT_PASSWORD"
    tls: bool = False
    ca_path: Path | None = None


@dataclass(frozen=True)
class AppConfig:
    device_id: str
    zones_path: Path
    camera: CameraConfig
    detector: DetectorConfig
    occupancy: OccupancyConfig
    mqtt: MQTTConfig
    poll_seconds: float = 0.2
    log_level: str = "INFO"


def read_yaml(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        try:
            data = yaml.safe_load(handle)
        except yaml.YAMLError as exc:
            raise ValueError(f"{path}: invalid YAML: {exc}") from exc
    if not isinstance(data, dict):
        raise ValueError(f"{path}: expected a YAML mapping")
    return data


def _section(cls: type[T], values: Any) -> T:
    if not isinstance(values, dict):
        raise ValueError(f"{cls.__name__} must be a mapping")
    unknown = values.keys() - {f.name for f in fields(cls)}
    if unknown:
        raise ValueError(f"Unknown {cls.__name__} keys: {sorted(unknown)}")
    try:
        return cls(**values)
    except TypeError as exc:
        raise ValueError(f"Invalid {cls.__name__}: {exc}") from exc


def _number(value: Any, name: str, low: float, high: float, *, integer: bool = False) -> None:
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(value)
        or not low <= value <= high
        or (integer and not isinstance(value, int))
    ):
        raise ValueError(
            f"{name} must be {'an integer' if integer else 'a number'} in [{low}, {high}]"
        )


def load_config(path: Path | str = REPO_ROOT / "config/config.yaml") -> AppConfig:
    path = Path(path).resolve()
    data = read_yaml(path)
    base = path.parent
    for name in ("camera", "detector", "occupancy", "mqtt"):
        if not isinstance(data.get(name), dict):
            raise ValueError(f"Missing configuration section: {name}")
    detector = dict(data["detector"])
    for key in ("model_path", "labels_path"):
        if not isinstance(detector.get(key), str):
            raise ValueError(f"detector.{key} must be a path string")
        detector[key] = (base / detector[key]).resolve()
    mqtt = dict(data["mqtt"])
    if mqtt.get("ca_path") is not None:
        if not isinstance(mqtt["ca_path"], str) or not mqtt["ca_path"]:
            raise ValueError("mqtt.ca_path must be null or a nonempty path string")
        mqtt["ca_path"] = (base / mqtt["ca_path"]).resolve()
    if not isinstance(data.get("zones_path"), str):
        raise ValueError("zones_path must be a path string")
    data.update(
        zones_path=(base / data["zones_path"]).resolve(),
        camera=_section(CameraConfig, data["camera"]),
        detector=_section(DetectorConfig, detector),
        occupancy=_section(OccupancyConfig, data["occupancy"]),
        mqtt=_section(MQTTConfig, mqtt),
    )
    cfg = _section(AppConfig, data)
    if not isinstance(cfg.device_id, str) or not re.fullmatch(
        r"[A-Za-z0-9_-]{1,64}", cfg.device_id
    ):
        raise ValueError("device_id must contain 1-64 letters, digits, underscores or hyphens")
    for name in ("width", "height"):
        _number(getattr(cfg.camera, name), f"camera.{name}", 32, 1920, integer=True)
    _number(cfg.camera.fps, "camera.fps", 1, 30)
    _number(cfg.camera.timeout_seconds, "camera.timeout_seconds", 0.1, 30)
    for value in (cfg.camera.hflip, cfg.camera.vflip, cfg.mqtt.tls):
        if not isinstance(value, bool):
            raise ValueError("Camera flips and mqtt.tls must be YAML booleans")
    d = cfg.detector
    if d.input_encoding not in ("raw_uint8", "normalized_real"):
        raise ValueError("detector.input_encoding must be raw_uint8 or normalized_real")
    if d.input_encoding == "raw_uint8" and d.input_dtype != "uint8":
        raise ValueError("raw_uint8 encoding requires uint8 model input")
    if d.input_dtype not in ("uint8", "int8", "float32"):
        raise ValueError("detector.input_dtype must be uint8, int8 or float32")
    if not isinstance(d.sha256, str) or not re.fullmatch(r"[a-fA-F0-9]{64}", d.sha256):
        raise ValueError("detector.sha256 must be a verified 64-digit SHA256")
    _number(d.input_mean, "detector.input_mean", -10000, 10000)
    _number(d.input_std, "detector.input_std", 0.000001, 10000)
    _number(d.input_scale, "detector.input_scale", 0, 10000)
    _number(d.input_zero_point, "detector.input_zero_point", -32768, 32767, integer=True)
    if d.input_dtype != "float32" and d.input_scale <= 0:
        raise ValueError("Quantized input needs a positive input_scale")
    for name in ("input_width", "input_height"):
        _number(getattr(d, name), f"detector.{name}", 1, 1024, integer=True)
    _number(d.num_threads, "detector.num_threads", 1, 4, integer=True)
    _number(d.confidence_threshold, "detector.confidence_threshold", 0, 1)
    _number(d.person_class_id, "detector.person_class_id", 0, 10000, integer=True)
    outputs = [d.boxes_output, d.classes_output, d.scores_output, d.count_output]
    for output in outputs:
        _number(output, "detector output position", 0, 3, integer=True)
    if len(set(outputs)) != 4:
        raise ValueError("SSD output positions must be distinct")
    for name in ("enter_seconds", "clear_seconds", "stale_seconds"):
        _number(getattr(cfg.occupancy, name), f"occupancy.{name}", 0.01, 3600)
    for name in ("enter_hits", "clear_misses"):
        _number(getattr(cfg.occupancy, name), f"occupancy.{name}", 1, 1000, integer=True)
    _number(cfg.poll_seconds, "poll_seconds", 0.01, 10)
    _number(cfg.mqtt.port, "mqtt.port", 1, 65535, integer=True)
    _number(cfg.mqtt.keepalive, "mqtt.keepalive", 5, 300, integer=True)
    _number(cfg.mqtt.heartbeat_seconds, "mqtt.heartbeat_seconds", 0.1, 60)
    _number(cfg.mqtt.expiry_seconds, "mqtt.expiry_seconds", 1, 300, integer=True)
    if cfg.mqtt.expiry_seconds <= max(cfg.mqtt.heartbeat_seconds, cfg.occupancy.stale_seconds):
        raise ValueError("MQTT expiry must exceed heartbeat and observation stale timeout")
    for name in ("host", "client_id", "topic_prefix", "username_env", "password_env"):
        value = getattr(cfg.mqtt, name)
        if not isinstance(value, str) or not value or any(c in value for c in ("\x00", "\n", "\r")):
            raise ValueError(f"mqtt.{name} must be a nonempty single-line string")
    if any(c in cfg.mqtt.topic_prefix for c in ("+", "#")) or cfg.mqtt.topic_prefix.endswith("/"):
        raise ValueError("mqtt.topic_prefix must have no wildcards or trailing slash")
    if cfg.log_level not in ("DEBUG", "INFO", "WARNING", "ERROR"):
        raise ValueError("Unsupported log_level")
    return cfg
