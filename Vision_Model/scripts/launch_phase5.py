"""Unattended launcher deliberately permits OBSERVE only; never persists an arming grant."""

import argparse
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from src.phase5_config import load_phase5  # noqa: E402
from src.phase5_runtime import run_service  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--run-root", type=Path, required=True)
    args = parser.parse_args()
    config = load_phase5(args.config)
    if config.mode != "OBSERVE":
        raise ValueError("Unattended launcher allows OBSERVE only; use supervised session arming")
    args.run_root.mkdir(parents=True, exist_ok=True)
    if len(list(args.run_root.iterdir())) >= 32:
        raise ValueError(
            "Run-directory retention bound reached; operator must export/archive old logs"
        )
    return run_service(config, args.run_root / uuid.uuid4().hex)


if __name__ == "__main__":
    raise SystemExit(main())
