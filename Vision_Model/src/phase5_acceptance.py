"""Hardware evidence templates and external-clock timing analysis. Never authorizes a load."""

from __future__ import annotations

import csv
import json
import math
from pathlib import Path

from .phase5_config import digest
from .phase5_metrics import statistics
from .zones import ZONE_IDS

TESTS = (
    "environment",
    "camera",
    "ssd",
    "crop_strategies",
    "physical_calibration",
    "mqtt",
    "isolated_outputs",
    "arrival_latency",
    "faults",
    "extended_operation",
    "electrical_commissioning",
)


def templates(output):
    output = Path(output)
    output.mkdir(parents=True, exist_ok=False)
    document = {
        "schema_version": 1,
        "hardware_acceptance": "PENDING",
        "mains_authorized": False,
        "tests": {
            name: {
                "status": "PENDING",
                "reviewer": "",
                "measured_at": None,
                "evidence_files": [],
                "notes": "",
            }
            for name in TESTS
        },
    }
    (output / "hardware_results.json").write_text(json.dumps(document, indent=2) + "\n")
    with (output / "external_trials.csv").open("x", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            (
                "trial_id",
                "zone",
                "phase",
                "source",
                "clock_id",
                "arrival_seconds",
                "output_seconds",
                "evidence_file",
                "evidence_sha256",
            )
        )
        for zone in ZONE_IDS:
            writer.writerow(
                (
                    f"PENDING-{zone}",
                    zone,
                    "sustained",
                    "external_synchronized_observation",
                    "",
                    "",
                    "",
                    "",
                    "",
                )
            )
    return document


def external_trials(path):
    path = Path(path)
    groups = {}
    invalid = []
    seen = set()
    with path.open(newline="") as handle:
        for row in csv.DictReader(handle):
            try:
                if (
                    row["trial_id"] in seen
                    or not row["trial_id"].strip()
                    or row["zone"] not in ZONE_IDS
                    or row["phase"] not in ("cold_start", "sustained")
                    or row["source"] != "external_synchronized_observation"
                    or not row["clock_id"].strip()
                    or not row["evidence_file"].strip()
                ):
                    raise ValueError("Missing/duplicate external event provenance")
                arrival, output = float(row["arrival_seconds"]), float(row["output_seconds"])
                if not math.isfinite(arrival) or not math.isfinite(output) or output < arrival:
                    raise ValueError("Invalid same-instrument timing pair")
                evidence = (path.parent / row["evidence_file"]).resolve()
                if digest(evidence) != row["evidence_sha256"]:
                    raise ValueError("External observation evidence hash mismatch")
                seen.add(row["trial_id"])
                groups.setdefault((row["zone"], row["phase"]), []).append(output - arrival)
            except (KeyError, ValueError, OSError) as exc:
                invalid.append({"trial_id": row.get("trial_id"), "reason": str(exc)})
    return {
        "measurement_type": "externally_observed_arrival_to_test_output",
        "deadline_seconds": 5,
        "groups": [
            {"zone": z, "phase": p, **statistics(values, 5)} for (z, p), values in groups.items()
        ],
        "invalid_or_incomplete": invalid,
        "physical_evidence_independently_reviewed_by_software": False,
        "mains_authorized": False,
        "status": "REQUIRES_HUMAN_EVIDENCE_REVIEW" if groups else "PENDING",
    }
