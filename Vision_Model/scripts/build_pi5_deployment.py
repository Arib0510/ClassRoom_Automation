#!/usr/bin/env python3
"""Build and verify the allowlisted self-contained Pi 5 deployment ZIP."""
from __future__ import annotations

import argparse
import hashlib
import json
import zipfile
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
ARCHIVE_ROOT = "Classroom_Vision_Pi5_Deployment"
EXPECTED_MODEL = "models/classroom_yolo_best.pt"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def selected_files(root: Path = ROOT) -> list[Path]:
    names = [
        "README_DEPLOYMENT.md",
        "requirements-pi5.txt",
        "requirements-pi5-support.txt",
        "config/mqtt.env.example",
        "config/six_zone_runtime.json",
        "models/classroom_yolo_best.pt",
        "scripts/run_classroom_vision.py",
        "scripts/install_pi5.sh",
        "scripts/run_dry_run.sh",
        "scripts/check_pi5_environment.py",
        "scripts/smoke_test_pi5_inference.py",
        "scripts/mqtt_nonactuating_probe.py",
        "src/ac_control.py",
        "src/classroom_tracker.py",
        "src/offline_diagnostics.py",
    ]
    files = [root / name for name in names]
    missing = [str(path) for path in files if not path.is_file()]
    if missing:
        raise FileNotFoundError("Required package file missing: " + ", ".join(missing))
    if sha256(root / EXPECTED_MODEL) != sha256(root / "yolov8n_classroom.pt"):
        raise ValueError("Current selected trained model copy no longer matches root model")
    return files


def build(output: Path, root: Path = ROOT) -> Path:
    output.parent.mkdir(parents=True, exist_ok=True)
    model_hash = sha256(root / EXPECTED_MODEL)
    manifest = {
        "schema_version": 1,
        "target": "Raspberry Pi 5, Raspberry Pi OS 64-bit, aarch64",
        "mode": "DRY_RUN_ONLY",
        "physical_appliance_commands": False,
        "model": {"path": EXPECTED_MODEL, "sha256": model_hash},
        "files": {},
    }
    files = selected_files(root)
    for path in files:
        relative = path.relative_to(root).as_posix()
        manifest["files"][relative] = {
            "sha256": sha256(path),
            "bytes": path.stat().st_size,
        }
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path in files:
            name = path.relative_to(root).as_posix()
            archive.write(path, f"{ARCHIVE_ROOT}/{name}")
        archive.writestr(
            f"{ARCHIVE_ROOT}/package_manifest.json",
            json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        )
    verify(output)
    output.with_suffix(output.suffix + ".sha256").write_text(
        f"{sha256(output)}  {output.name}\n", encoding="ascii"
    )
    return output


def verify(archive_path: Path) -> dict:
    with zipfile.ZipFile(archive_path) as archive:
        names = archive.namelist()
        expected_prefix = ARCHIVE_ROOT + "/"
        if any(not name.startswith(expected_prefix) for name in names):
            raise ValueError("Archive has an unexpected top-level path")
        if len(names) != len(set(names)):
            raise ValueError("Archive contains duplicate paths")
        banned = (".venv", "dataset/", "runs/", "credentials", "secrets.h")
        if any(
            any(marker in name.lower() for marker in banned)
            or name.lower().endswith("/config/mqtt.env")
            for name in names
        ):
            raise ValueError("Archive includes a forbidden development or secret file")
        manifest_path = f"{ARCHIVE_ROOT}/package_manifest.json"
        manifest = json.loads(archive.read(manifest_path))
        for relative, record in manifest["files"].items():
            path = PurePosixPath(relative)
            if path.is_absolute() or ".." in path.parts or "\\" in relative:
                raise ValueError(f"Unsafe archive path: {relative}")
            payload = archive.read(f"{ARCHIVE_ROOT}/{relative}")
            if len(payload) != record["bytes"] or hashlib.sha256(payload).hexdigest() != record["sha256"]:
                raise ValueError(f"Archive checksum/size mismatch: {relative}")
        if manifest["mode"] != "DRY_RUN_ONLY" or manifest["physical_appliance_commands"]:
            raise ValueError("Archive safety mode is invalid")
        return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    archive = build(args.output)
    manifest = verify(archive)
    print(json.dumps({
        "archive": str(archive.resolve()),
        "sha256": sha256(archive),
        "files_verified": len(manifest["files"]),
        "model_sha256": manifest["model"]["sha256"],
        "hardware_tested": False,
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
