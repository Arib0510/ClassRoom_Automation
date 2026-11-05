"""Lossless camera-frame collection and explicit opt-in image export; no detector or MQTT."""

from __future__ import annotations

import argparse
import json
import os
import time
import uuid
import zipfile
from datetime import UTC, datetime
from pathlib import Path

from PIL import Image

from .phase5_config import digest, load_phase5
from .phase5_workers import BoundedWorker
from .zones import ZONE_IDS


class DatasetWriter:
    def __init__(self, folder, session):
        self.folder = Path(folder)
        self.folder.mkdir(parents=True, mode=0o700, exist_ok=False)
        self.session = session
        self.records = []
        (self.folder / "session.json").write_text(json.dumps(session, indent=2) + "\n")
        self.journal = (self.folder / "frames.jsonl").open("x", encoding="utf-8")

    def save(self, frame, lighting, human_zones=None):
        if len(self.records) >= 4096:
            raise ValueError("Dataset session bound reached; open a new collection session")
        zones = human_zones or dict.fromkeys(ZONE_IDS, "UNKNOWN")
        if set(zones) != set(ZONE_IDS) or any(
            s not in ("OCCUPIED", "VACANT", "UNKNOWN") for s in zones.values()
        ):
            raise ValueError("Human labels require four explicit physical states")
        if not isinstance(lighting, str) or not lighting.strip() or len(lighting) > 100:
            raise ValueError("Lighting description required; do not enter student identities")
        filename = f"frame_{len(self.records) + 1:05d}.png"
        path = self.folder / filename
        Image.fromarray(frame["rgb"]).save(path)
        info = {k: v for k, v in frame.items() if k != "rgb"}
        record = {
            "file_name": filename,
            "sha256": digest(path),
            "width": frame["rgb"].shape[1],
            "height": frame["rgb"].shape[0],
            "capture": info,
            "saved_at_utc": datetime.now(UTC).isoformat(),
            "lighting": lighting,
            "physical_occupancy": zones,
            "annotation_source": "human_entered_or_UNKNOWN",
            "consent_reference": self.session.get("consent_reference"),
            "encoding": "lossless RGB PNG; not raw Bayer sensor data",
        }
        self.records.append(record)
        self.journal.write(json.dumps(record, allow_nan=False) + "\n")
        self.journal.flush()
        return record

    def close(self):
        self.journal.close()
        manifest = {
            "schema_version": 1,
            "session": self.session,
            "images": self.records,
            "ground_truth_from_predictions": False,
        }
        with (self.folder / "manifest.json").open("x", encoding="utf-8") as handle:
            json.dump(manifest, handle, indent=2, allow_nan=False)
        return manifest


def export_dataset(folder, output, include_images=False):
    folder, output = Path(folder), Path(output)
    if output.exists():
        raise ValueError("Dataset export preserves existing files")
    manifest = json.loads((folder / "manifest.json").read_text())
    sanitized = {
        "schema_version": 1,
        "session_id": manifest["session"]["session_id"],
        "images_included": include_images,
        "images": [],
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_DEFLATED) as archive:
        for record in manifest["images"]:
            name = record["file_name"]
            if Path(name).name != name or not name.endswith(".png"):
                raise ValueError("Unsafe dataset image path")
            path = folder / name
            if digest(path) != record["sha256"]:
                raise ValueError("Dataset source checksum changed")
            sanitized["images"].append(
                {
                    k: record[k]
                    for k in (
                        "file_name",
                        "sha256",
                        "width",
                        "height",
                        "lighting",
                        "physical_occupancy",
                        "annotation_source",
                    )
                }
            )
            if include_images:
                archive.write(path, name)
        archive.writestr("manifest.json", json.dumps(sanitized, indent=2))
    return sanitized


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("collect", "export"))
    parser.add_argument("--config", type=Path, default=Path("config/phase5.example.yaml"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--input", type=Path)
    parser.add_argument("--include-images", action="store_true")
    parser.add_argument("--interval", type=float, default=5)
    parser.add_argument("--count", type=int, default=30)
    parser.add_argument("--manual", action="store_true")
    parser.add_argument("--lighting", default="UNKNOWN")
    parser.add_argument("--consent-reference")
    parser.add_argument("--human-zones", type=Path)
    args = parser.parse_args(argv)
    if args.command == "export":
        if args.input is None:
            raise ValueError("export needs --input dataset directory")
        result = export_dataset(args.input, args.output, args.include_images)
        print(
            json.dumps(
                {"images_included": result["images_included"], "records": len(result["images"])}
            )
        )
        return 0
    import platform

    if platform.system() != "Linux" or platform.machine() not in ("armv7l", "armv8l"):
        raise ValueError("Camera collection is a target-only operation")
    if (
        not args.consent_reference
        or not 1 <= args.count <= 4096
        or not 0.1 <= args.interval <= 3600
    ):
        raise ValueError("Collection needs consent reference, count 1..4096, interval .1..3600")
    os.umask(0o077)
    config = load_phase5(args.config)
    zones = json.loads(args.human_zones.read_text()) if args.human_zones else None
    writer = DatasetWriter(
        args.output,
        {
            "session_id": uuid.uuid4().hex,
            "camera": config.data["camera"],
            "consent_reference": args.consent_reference,
            "commissioning": config.data["commissioning"],
            "config_fingerprint": config.fingerprint,
            "capture_utc": datetime.now(UTC).isoformat(),
            "retention": "operator-managed; no automatic publication",
        },
    )
    worker = BoundedWorker("camera", config.path)
    try:
        worker.wait_ready(config.data["resources"]["startup_timeout_seconds"])
        for _ in range(args.count):
            if args.manual and input("Enter captures; q ends collection: ").lower() == "q":
                break
            start = time.monotonic()
            frame = worker.call(None, config.base.camera.timeout_seconds + 0.25)
            print(json.dumps(writer.save(frame, args.lighting, zones)))
            if not args.manual:
                time.sleep(max(0, args.interval - (time.monotonic() - start)))
    finally:
        worker.close()
        writer.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
