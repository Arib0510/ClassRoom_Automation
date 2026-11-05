"""Read-only checks; never open camera, inference interpreter, sockets, or hardware."""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import importlib.util
import json
import platform
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--static", action="store_true", help="Host-neutral static checks (default)"
    )
    parser.add_argument(
        "--pi", action="store_true", help="Also verify Pi OS/ABI and package presence"
    )
    parser.add_argument("--config", type=Path, default=ROOT / "config/config.yaml")
    args = parser.parse_args()
    failures = []

    def check(ok: bool, message: str) -> None:
        print(f"{'PASS' if ok else 'FAIL'} {message}")
        if not ok:
            failures.append(message)

    check(
        (3, 11) <= sys.version_info[:2] < (3, 13), f"Python 3.11/3.12: {platform.python_version()}"
    )
    for distribution in ("numpy", "Pillow", "PyYAML", "paho-mqtt"):
        try:
            version = importlib.metadata.version(distribution)
            check(True, f"{distribution} {version}")
            if distribution == "numpy":
                check(int(version.split(".")[0]) < 2, "NumPy <2 for tflite-runtime 2.14 ABI")
        except importlib.metadata.PackageNotFoundError:
            check(False, f"Missing {distribution}")
    try:
        from src.config import load_config
        from src.detector import verify_model
        from src.zones import ZoneMap

        config = load_config(args.config)
        zones = ZoneMap.load(config.zones_path)
        verify_model(config.detector)
        check(True, "Configuration, four polygons, model hash and person label")
        print(
            "INFO Physical zone calibration: "
            + ("declared complete" if zones.calibrated else "PENDING")
        )
        manifest = json.loads((ROOT / "models/manifest.json").read_text(encoding="utf-8"))
        for artifact in manifest["artifacts"]:
            path = ROOT / "models" / artifact["file"]
            check(
                path.is_file()
                and hashlib.sha256(path.read_bytes()).hexdigest() == artifact["sha256"],
                f"Baseline artifact {path.name}",
            )
        if importlib.util.find_spec("tflite") and importlib.util.find_spec("flatbuffers"):
            from inspect_model import inspect_model

            actual = inspect_model(ROOT / "models/ssd_mobilenet_v2_coco_quant.tflite")
            recorded = json.loads((ROOT / "models/inspection.json").read_text(encoding="utf-8"))
            check(actual == recorded, "Static FlatBuffer inspection matches reviewed record")
        else:
            print("INFO Optional FlatBuffer schema absent; structural inspection skipped")
    except (OSError, ValueError, ImportError, KeyError) as exc:
        check(False, str(exc))
    if args.pi:
        check(sys.platform == "linux", "Linux target")
        check(sys.version_info[:2] == (3, 11), "Bookworm CPython 3.11 wheel ABI")
        check(struct.calcsize("P") == 4, "32-bit userland")
        check(
            platform.machine() in ("armv7l", "armv8l"),
            f"ARMv7 userland compatible machine: {platform.machine()}",
        )
        os_release = Path("/etc/os-release")
        release = os_release.read_text() if os_release.exists() else ""
        check("VERSION_CODENAME=bookworm" in release, "Bookworm OS")
        for module in ("picamera2", "libcamera", "tflite_runtime"):
            check(
                importlib.util.find_spec(module) is not None,
                f"Package present: {module} (not opened)",
            )
        try:
            check(importlib.metadata.version("tflite-runtime") == "2.14.0", "Pinned runtime 2.14.0")
        except importlib.metadata.PackageNotFoundError:
            check(False, "Missing tflite-runtime distribution")
    print("No camera, inference, network, accuracy, latency, or hardware tests performed.")
    return int(bool(failures))


if __name__ == "__main__":
    raise SystemExit(main())
