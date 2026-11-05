"""Bounded JSONL diagnostics and explicit provenance for duration statistics."""

from __future__ import annotations

import json
import logging
import math
import os
import time
from logging.handlers import RotatingFileHandler
from pathlib import Path

import numpy as np


class EventLog:
    def __init__(self, folder, limits, provenance):
        folder = Path(folder)
        folder.mkdir(parents=True, exist_ok=False)
        self.provenance = provenance
        self.logger = logging.Logger("phase5-" + folder.name)
        self.handler = RotatingFileHandler(
            folder / "events.jsonl",
            maxBytes=limits["max_bytes"],
            backupCount=limits["backup_count"],
            encoding="utf-8",
        )
        self.logger.addHandler(self.handler)
        self.logger.setLevel(logging.INFO)

    def write(self, event, **fields):
        self.logger.info(
            json.dumps(
                {
                    "event": event,
                    "provenance": self.provenance,
                    "monotonic": time.monotonic(),
                    **fields,
                },
                allow_nan=False,
            )
        )

    def close(self):
        self.handler.flush()
        self.handler.close()
        self.logger.removeHandler(self.handler)


def resources(pids=()):
    """Linux /proc counters; unavailable values are null, never guessed desktop/Pi values."""
    result = {
        "rss_mb": None,
        "total_rss_mb": None,
        "available_mb": None,
        "temperature_c": None,
        "process_cpu_seconds": time.process_time(),
        "cpu_utilization_percent": None,
    }
    try:
        rss = []
        cpu_ticks = 0
        for pid in (os.getpid(), *pids):
            status = Path(f"/proc/{pid}/status").read_text()
            rss.append(
                float(
                    next(
                        line.split()[1] for line in status.splitlines() if line.startswith("VmRSS:")
                    )
                )
                / 1024
            )
            stat = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
            cpu_ticks += int(stat[11]) + int(stat[12])
        result["rss_mb"], result["total_rss_mb"] = rss[0], sum(rss)
        result["process_tree_cpu_seconds"] = cpu_ticks / os.sysconf("SC_CLK_TCK")
        memory = Path("/proc/meminfo").read_text()
        result["available_mb"] = (
            float(
                next(
                    line.split()[1]
                    for line in memory.splitlines()
                    if line.startswith("MemAvailable:")
                )
            )
            / 1024
        )
        temperature = Path("/sys/class/thermal/thermal_zone0/temp")
        if temperature.exists():
            result["temperature_c"] = float(temperature.read_text()) / 1000
    except (OSError, ValueError, StopIteration, IndexError, AttributeError):
        pass
    return result


def statistics(values, deadline=None):
    valid = [
        float(v)
        for v in values
        if isinstance(v, (float, int)) and not isinstance(v, bool) and math.isfinite(v) and v >= 0
    ]
    count = len(valid)
    return {
        "sample_count": count,
        "invalid_or_incomplete": len(values) - count,
        "mean": float(np.mean(valid)) if count else None,
        "median": float(np.median(valid)) if count else None,
        "p90": float(np.percentile(valid, 90)) if count >= 10 else None,
        "p95": float(np.percentile(valid, 95)) if count >= 20 else None,
        "p99": float(np.percentile(valid, 99)) if count >= 100 else None,
        "maximum": max(valid) if count else None,
        "deadline_miss_count": sum(v > deadline for v in valid) if deadline is not None else None,
    }


def summarize(folder):
    groups = {}
    incomplete = 0
    events = {}
    latest_counters = None
    for path in sorted(Path(folder).glob("events.jsonl*")):
        for line in path.read_text(encoding="utf-8").splitlines():
            try:
                event = json.loads(line)
                kind = event.get("event", "unknown")
                events[kind] = events.get(kind, 0) + 1
                if kind == "shutdown":
                    latest_counters = event.get("counters")
                scope = (event["provenance"], event.get("phase", "sustained"))
                timings = event.get("timings", {})
                for key in (
                    "capture_duration_seconds",
                    "frame_age_seconds",
                    "frame_age_at_inference_start_seconds",
                    "zone_mapping_seconds",
                    "pipeline_seconds",
                    "acknowledgement_seconds",
                    "arrival_to_decision_seconds",
                    "mqtt_enqueue_seconds",
                ):
                    if key in event:
                        timings[key] = event[key]
                for key, value in timings.items():
                    groups.setdefault((scope, key), []).append(value)
            except (ValueError, KeyError, TypeError):
                incomplete += 1
    return {
        "groups": [
            {
                "provenance": scope[0],
                "phase": scope[1],
                "metric": metric,
                **statistics(values, 5 if metric.startswith("arrival") else None),
            }
            for (scope, metric), values in groups.items()
        ],
        "invalid_log_records": incomplete,
        "event_counts": events,
        "latest_control_counters": latest_counters,
        "resource_deadline_breach_events": events.get("resource_limit", 0),
        "physical_arrival_to_activation": {
            "status": "PENDING",
            "reason": "MQTT acknowledgements do not independently observe relay/load activation",
        },
        "note": "Rotated logs represent retained samples only, not an unbounded run history",
    }
