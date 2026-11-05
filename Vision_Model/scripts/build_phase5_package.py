"""Explicit allowlist Pi package, independent of existing wheel/sdist and experimental assets."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import zipfile
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))


def digest(path):
    with Path(path).open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def package_files(root=ROOT):
    src = [
        p
        for p in (root / "src").glob("*.py")
        if not p.name.startswith(("experimental_", "phase4_"))
    ]
    files = src + [
        root / f
        for f in (
            "AGENTS.md",
            "requirements-pi.txt",
            "config/config.yaml",
            "config/zones.yaml",
            "config/calibration.example.yaml",
            "config/phase5.example.yaml",
            "config/phase5_dependency_evidence.json",
            "scripts/check_environment.py",
            "scripts/inspect_model.py",
            "scripts/inspect_allocated_model.py",
            "scripts/pi_phase5_checks.py",
            "scripts/install_phase5.sh",
            "scripts/launch_phase5.py",
            "scripts/phase5_observe.service.in",
            "scripts/build_phase5_package.py",
        )
    ]
    files += list((root / "docs").glob("phase5_*.md"))
    files += [
        root / "models" / name
        for name in (
            "ssd_mobilenet_v2_coco_quant.tflite",
            "coco_labels.txt",
            "LICENSE.google-coral",
            "manifest.json",
            "inspection.json",
            "README.md",
        )
    ]
    return sorted(files, key=lambda p: p.relative_to(root).as_posix())


def manifest(root=ROOT):
    from src.phase5_config import load_phase5

    config = load_phase5(root / "config/phase5.example.yaml")
    if config.mode != "OBSERVE" or config.data["mqtt"]["enabled"]:
        raise ValueError("Package default must remain OBSERVE with networking disabled")
    return {
        "schema_version": 1,
        "target": {
            "os": "Raspberry Pi OS Bookworm 32-bit",
            "python": "3.11",
            "architecture": "ARMv7/armhf",
            "hardware": "Pi Zero 2 W, 512 MB",
        },
        "deployment_status": "PREPARED_NOT_HARDWARE_VALIDATED",
        "configuration_version": 1,
        "default_mode": "OBSERVE",
        "appliances_authorized": False,
        "model": {
            "id": "Coral CPU SSD MobileNetV2 COCO17 PTQ",
            "sha256": config.base.detector.sha256,
            "input": "RGB raw uint8 NHWC [1,300,300,3]",
            "output_positions": {"scores": 0, "boxes": 1, "count": 2, "classes": 3},
            "person_id": 0,
        },
        "runtime_dependencies": {
            "pip": ["tflite-runtime==2.14.0", "paho-mqtt==2.1.0"],
            "os": [
                "python3.11",
                "python3-numpy",
                "python3-pil",
                "python3-yaml",
                "python3-picamera2",
                "libcamera",
            ],
        },
        "files": {
            p.relative_to(root).as_posix(): {"sha256": digest(p), "bytes": p.stat().st_size}
            for p in package_files(root)
        },
    }


def verify(root):
    root = Path(root).resolve()
    data = json.loads((root / "package_manifest.json").read_text())
    if data.get("schema_version") != 1 or data.get("default_mode") != "OBSERVE":
        raise ValueError("Invalid package manifest")
    for name, record in data["files"].items():
        relative = PurePosixPath(name)
        if relative.is_absolute() or ".." in relative.parts or ":" in name or "\\" in name:
            raise ValueError("Unsafe package path")
        path = root / name
        if (
            path.is_symlink()
            or not path.is_file()
            or digest(path) != record["sha256"]
            or path.stat().st_size != record["bytes"]
        ):
            raise ValueError(f"Package checksum/size mismatch: {name}")
    for base in ("src", "scripts"):
        for path in (root / base).rglob("*.py"):
            if path.relative_to(root).as_posix() not in data["files"]:
                raise ValueError("Unexpected executable source in package")
    return data


def create(output, root=ROOT):
    output = Path(output)
    output.mkdir(parents=True, exist_ok=False)
    data = manifest(root)
    archive = output / "classroom-phase5-bookworm-armhf.zip"
    with zipfile.ZipFile(archive, "x", compression=zipfile.ZIP_DEFLATED) as zipped:
        for name in data["files"]:
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (0o100700 if name.endswith(".sh") else 0o100600) << 16
            zipped.writestr(info, (root / name).read_bytes())
        zipped.writestr("package_manifest.json", json.dumps(data, indent=2, sort_keys=True) + "\n")
    (output / "package_manifest.json").write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    (output / "archive_sha256.txt").write_text(digest(archive) + "  " + archive.name + "\n")
    return archive


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("create", "verify"))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args()
    if args.command == "create":
        if args.output is None:
            parser.error("create requires NEW --output directory")
        print(create(args.output, args.root))
    else:
        print(
            json.dumps(
                {"verified_files": len(verify(args.root)["files"]), "hardware_tested": False}
            )
        )


if __name__ == "__main__":
    main()
