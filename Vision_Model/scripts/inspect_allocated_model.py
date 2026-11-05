"""Allocate the real reviewed model and serialize observed tensor metadata; no inference."""

from __future__ import annotations

import argparse
import json
import platform
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))


def main() -> int:
    from src.config import load_config
    from src.detector import create_detector

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=ROOT / "config/config.yaml")
    parser.add_argument(
        "--runtime", choices=("auto", "tensorflow", "tflite-runtime"), default="auto"
    )
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    record = {
        "status": "initializing",
        "python_version": platform.python_version(),
        "python_executable": sys.executable,
        "platform": platform.platform(),
        "requested_runtime": args.runtime,
        "inference_executed": False,
    }
    try:
        config = load_config(args.config)
        record["model_filename"] = config.detector.model_path.name
        record["verified_model_sha256"] = config.detector.sha256
        detector = create_detector(config.detector, backend=args.runtime)
        record.update(
            status="allocated",
            runtime=detector.runtime_info,
            allocated_tensors=detector.allocated_metadata(),
        )
    except Exception as exc:
        record.update(status="failed", error_type=type(exc).__name__, error=str(exc))
    encoded = json.dumps(record, indent=2, allow_nan=False) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded, encoding="utf-8")
    print(encoded, end="")
    return 0 if record["status"] == "allocated" else 1


if __name__ == "__main__":
    raise SystemExit(main())
