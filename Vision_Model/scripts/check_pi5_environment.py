#!/usr/bin/env python3
"""Static deployment checks; does not open the camera, connect MQTT, or infer."""
from __future__ import annotations

import hashlib
import importlib.metadata
import platform
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXPECTED_MODEL_SHA256 = "25c22208ac714cc571204c7b39f58b460bb01e9b18e59fab7033fce6c06a928c"


def main() -> int:
    failures = []

    def check(ok: bool, message: str) -> None:
        print(f"{'PASS' if ok else 'FAIL'} {message}")
        if not ok:
            failures.append(message)

    check(sys.version_info >= (3, 13), f"Python >=3.13: {platform.python_version()}")
    check(struct.calcsize("P") == 8, "64-bit Python userland")
    check(platform.machine() == "aarch64", f"ARM64 architecture: {platform.machine()}")
    expected = {
        "torch": "2.8.0",
        "torchvision": "0.23.0",
        "ultralytics": "8.3.223",
        "paho-mqtt": "2.1.0",
    }
    for package in ("numpy", "paho-mqtt", "torch", "torchvision", "ultralytics"):
        try:
            version = importlib.metadata.version(package)
            check(True, f"{package} {version}")
            if package == "numpy":
                parsed = tuple(int(part) for part in version.split(".")[:2])
                check((2, 2) <= parsed < (2, 3), "NumPy 2.2.x (Trixie system package)")
                check(version == "2.2.4", "Preserve Debian Trixie NumPy 2.2.4")
            elif package in expected:
                check(version == expected[package], f"{package} pinned wheel version {expected[package]}")
        except importlib.metadata.PackageNotFoundError:
            check(False, f"Missing Python distribution: {package}")

    try:
        import cv2
        import numpy as np
        from pathlib import Path
        from picamera2 import Picamera2
        from ultralytics import YOLO

        del np, Picamera2, YOLO
        check(cv2.__version__ == "4.10.0", f"Preserve system OpenCV 4.10.0 (found {cv2.__version__})")
        paths = {
            "NumPy": __import__("numpy").__file__,
            "OpenCV": cv2.__file__,
            "Picamera2": __import__("picamera2").__file__,
        }
        venv = (ROOT / ".venv-pi5").resolve()
        for label, location in paths.items():
            resolved = Path(location).resolve()
            check(venv not in resolved.parents, f"{label} loaded from system site packages: {resolved}")
    except Exception as exc:
        check(False, f"vision/camera modules import: {type(exc).__name__}: {exc}")

    model = ROOT / "models/classroom_yolo_best.pt"
    if model.is_file():
        digest = hashlib.sha256(model.read_bytes()).hexdigest()
        check(not EXPECTED_MODEL_SHA256 or digest == EXPECTED_MODEL_SHA256,
              f"Selected model hash {digest}")
    else:
        check(False, f"Selected model exists: {model}")
    zones = ROOT / "config/six_zone_runtime.json"
    check(zones.is_file(), "Six-zone runtime settings present")
    env_file = ROOT / "config/mqtt.env"
    if env_file.is_file():
        check(True, "Private config/mqtt.env exists (permissions should be 600)")
    else:
        print("INFO MQTT credentials not configured yet; copy config/mqtt.env.example after install.")
    print("NOT TESTED: Camera capture/orientation, inference throughput, and broker reachability.")
    return int(bool(failures))


if __name__ == "__main__":
    raise SystemExit(main())
