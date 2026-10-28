"""Deterministic shared-pipeline scenario. Python-only indicators, no socket/GPIO implementation."""

from __future__ import annotations

import argparse
import copy
import json
from dataclasses import replace
from pathlib import Path

from .phase5_config import PROTOCOL, load_phase5
from .phase5_mqtt import MemoryTransport
from .phase5_occupancy import ZoneEvidence, unknown
from .phase5_protocol import ReferenceController
from .phase5_runtime import Pipeline
from .zones import ZONE_IDS


class SyntheticInterlock:
    """Cannot be used with a real transport. No CLI live application selects this interlock."""

    grant = None

    def __init__(self, transport):
        if type(transport) is not MemoryTransport:
            raise ValueError("Synthetic interlock requires network-incapable MemoryTransport")
        self.transport = transport

    def permits(self, appliance, now, unix):
        return True, "SYNTHETIC_SOFTWARE_ONLY"


class Trace:
    def __init__(self):
        self.records = []

    def write(self, event, **fields):
        self.records.append({"source": "synthetic", "event": event, **fields})


def simulate():
    cfg = load_phase5()
    data = copy.deepcopy(cfg.data)
    data["mode"] = "LIVE_TEST"  # Only fake outputs, never authorization for a real transport.
    data["mqtt"]["prefix"] = "synthetic/phase5"
    data["controllers"] = [{"id": f"synthetic_board_{i}", "protocol": PROTOCOL} for i in (1, 2, 3)]
    data["appliances"] = [
        {
            "id": "synthetic_" + z,
            "zone": z,
            "controller": f"synthetic_board_{min(i // 2 + 1, 3)}",
            "channel": "synthetic_indicator_" + str(i),
            "off_delay_seconds": 0,
        }
        for i, z in enumerate(ZONE_IDS)
    ]
    # Synthetic example only; these are not installed controller mappings.
    data["appliances"][-1]["controller"] = "synthetic_board_3"
    cfg = replace(cfg, data=data)
    transport = MemoryTransport(True)
    trace = Trace()
    pipeline = Pipeline(
        cfg,
        transport,
        "synthetic-session",
        interlock=SyntheticInterlock(transport),
        log=trace,
        clock_valid=True,
    )
    counter = 0

    def token():
        nonlocal counter
        counter += 1
        return f"synthetic_token_{counter}"

    pipeline.engine.token = token
    boards = {
        c["id"]: ReferenceController(
            c["id"],
            "synthetic_boot_1",
            pipeline.engine.appliances,
            local_policy="HOLD",
            mode="LIVE_TEST",
        )
        for c in data["controllers"]
    }
    pipeline.mark_arrival("synthetic_arrival", "front_left", 0)
    observations = []
    for i in range(85):
        now, unix = i / 4, 1_800_000_000 + i / 4
        if now == 3:
            transport.connected = False
        if now == 4:
            transport.connected = True
            transport.generation += 1
        if now == 6:
            boards["synthetic_board_1"].boot = "synthetic_boot_2"
        if now in (2, 3):
            evidence = unknown("synthetic_camera_failure")
        else:
            evidence = {
                z: ZoneEvidence(
                    "OCCUPIED" if now < 5 else "VACANT",
                    1 if now < 5 else 0,
                    0.8 if now < 5 else None,
                    "SYNTHETIC_VERIFIED_COVERAGE_FIXTURE",
                )
                for z in ZONE_IDS
            }
        pipeline.temporal.update(f"synthetic-frame-{i}", now, evidence, now)
        if transport.connected:
            for cid, board in boards.items():
                board.tick(now)
                if board.challenge is not None:
                    status = board.status(unix)
                    transport.incoming.append(
                        (f"synthetic/phase5/controllers/{cid}/status", json.dumps(status), False)
                    )
        zones, decisions = pipeline.tick(now, unix)
        while transport.sent:
            topic, packet, qos, retained = transport.sent.popleft()
            if "/controllers/" not in topic:
                continue
            cid = packet.get("controller_id") or topic.split("/")[-2]
            board = boards[cid]
            if topic.endswith("/hello"):
                response = board.hello(packet, unix)
            elif topic.endswith("/command"):
                response = board.command(packet, now, unix)
            else:
                continue
            transport.incoming.append(
                (
                    f"synthetic/phase5/controllers/{cid}/{response['kind']}",
                    json.dumps(response),
                    False,
                )
            )
        observations.append(
            {
                "time": now,
                "zones": {z: s["state"] for z, s in zones.items()},
                "desired": {a: s["desired"] for a, s in decisions.items()},
                "simulated_outputs": {
                    a: value for b in boards.values() for a, value in b.outputs.items()
                },
            }
        )
    return {
        "source": "deterministic_synthetic_software",
        "hardware_tested": False,
        "mqtt_sockets_used": False,
        "gpio_used": False,
        "controller_watchdogs": "Python reference only; real firmware pending",
        "scenarios": [
            "arrival",
            "vacancy_delay",
            "camera_fault",
            "broker_loss",
            "reconnect",
            "controller_reboot",
        ],
        "observations": observations,
        "events": trace.records,
        "counters": pipeline.engine.counters,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    if args.output.exists():
        raise ValueError("Choose a new simulation output")
    result = simulate()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
    print(
        json.dumps(
            {"source": result["source"], "counters": result["counters"], "hardware_tested": False}
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
