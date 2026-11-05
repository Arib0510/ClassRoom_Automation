"""Tests for Phase 5 AppBridge, manual overrides, and app telemetry state."""

import json
from pathlib import Path
import pytest
import yaml

from src.phase5_config import load_phase5
from src.phase5_control import ApplianceEngine
from src.phase5_mqtt import MemoryTransport
from src.phase5_safety import OperatorGrant, SafetyInterlock
from src.zones import ZONE_IDS


@pytest.fixture
def bridge_fixture(tmp_path):
    data = yaml.safe_load(Path("config/phase5.example.yaml").read_text())
    data["base_config"] = str(Path("config/config.yaml").resolve())
    data["mode"] = "DRY_RUN"
    data["mqtt"].update(enabled=True, prefix="classpulse/room01", ack_timeout_seconds=0.5)

    evidence = tmp_path / "evidence.txt"
    evidence.write_text("SYNTHETIC test fixture")
    data["controllers"] = [
        {
            "id": "board01",
            "protocol": "classroom-control-v1",
            "firmware_sha256": "f" * 64,
            "verified": True,
            "evidence": str(evidence),
            "dry_run_enforced": True,
            "local_fault_policy": "HOLD",
        }
    ]
    data["appliances"] = [
        {
            "id": "fan_1",
            "zone": "front_left",
            "controller": "board01",
            "channel": "relay_1",
            "ownership_verified": True,
            "test_output_isolated": True,
            "off_delay_seconds": 0,
        }
    ]

    conf_file = tmp_path / "phase5.yaml"
    conf_file.write_text(yaml.safe_dump(data))
    config = load_phase5(conf_file)

    transport = MemoryTransport(connected=True)
    interlock = SafetyInterlock(config, None, "test-session")
    engine = ApplianceEngine(config, transport, interlock, "test-session", clock_valid=True)
    return engine, transport, config


def test_app_bridge_valid_request(bridge_fixture):
    engine, transport, config = bridge_fixture
    now, unix = 100.0, 1_700_000_100.0

    # Ingress manual ON request from Flutter app
    req_payload = {
        "request_id": "req-12345",
        "appliance_id": "fan_1",
        "desired_state": "ON",
        "duration_seconds": 60,
        "operator": "test_operator",
        "sent_at_unix_ms": int(unix * 1000),
    }
    transport.incoming.append(("classpulse/room01/app/requests", json.dumps(req_payload), False))

    # Step engine
    snapshot = {z: {"state": "VACANT", "observed_at": now} for z in ZONE_IDS}
    engine.step(snapshot, now, unix)

    # Check published results
    results = [msg for msg in transport.sent if msg[0] == "classpulse/room01/app/results"]
    assert len(results) >= 1
    res_topic, res_payload, _, _ = results[0]
    res_doc = json.loads(res_payload) if isinstance(res_payload, str) else res_payload
    assert res_doc["request_id"] == "req-12345"
    assert res_doc["result"] == "ACCEPTED"
    assert res_doc["desired_state"] == "ON"

    # Verify override is stored in engine
    assert "fan_1" in engine.overrides
    assert engine.overrides["fan_1"][0] == "ON"
    assert engine.overrides["fan_1"][1] == "test_operator"


def test_app_bridge_unknown_appliance_rejected(bridge_fixture):
    engine, transport, config = bridge_fixture
    now, unix = 100.0, 1_700_000_100.0

    req_payload = {
        "request_id": "bad-req-1",
        "appliance_id": "non_existent_fan",
        "desired_state": "ON",
    }
    transport.incoming.append(("classpulse/room01/app/requests", json.dumps(req_payload), False))

    snapshot = {z: {"state": "VACANT", "observed_at": now} for z in ZONE_IDS}
    engine.step(snapshot, now, unix)

    results = [msg for msg in transport.sent if msg[0] == "classpulse/room01/app/results"]
    assert len(results) >= 1
    res_doc = json.loads(results[0][1]) if isinstance(results[0][1], str) else results[0][1]
    assert res_doc["request_id"] == "bad-req-1"
    assert res_doc["result"] == "REJECTED"
    assert "Unknown appliance_id" in res_doc["reason"]


def test_app_bridge_auto_clears_override(bridge_fixture):
    engine, transport, config = bridge_fixture
    now, unix = 100.0, 1_700_000_100.0

    # Set initial override
    engine.override("fan_1", "ON", "manual_operator", now + 120, now)
    assert "fan_1" in engine.overrides

    # Send AUTO request
    req_payload = {
        "request_id": "clear-req-1",
        "appliance_id": "fan_1",
        "desired_state": "AUTO",
    }
    transport.incoming.append(("classpulse/room01/app/requests", json.dumps(req_payload), False))

    snapshot = {z: {"state": "VACANT", "observed_at": now} for z in ZONE_IDS}
    engine.step(snapshot, now, unix)

    # Verify override was cleared
    assert "fan_1" not in engine.overrides

    results = [msg for msg in transport.sent if msg[0] == "classpulse/room01/app/results"]
    res_doc = json.loads(results[-1][1]) if isinstance(results[-1][1], str) else results[-1][1]
    assert res_doc["request_id"] == "clear-req-1"
    assert res_doc["result"] == "ACCEPTED"


def test_app_bridge_publishes_state(bridge_fixture):
    engine, transport, config = bridge_fixture
    now, unix = 100.0, 1_700_000_100.0

    snapshot = {z: {"state": "OCCUPIED", "observed_at": now} for z in ZONE_IDS}
    engine.step(snapshot, now, unix)

    state_msgs = [msg for msg in transport.sent if msg[0] == "classpulse/room01/app/state"]
    assert len(state_msgs) >= 1
    state_doc = json.loads(state_msgs[0][1]) if isinstance(state_msgs[0][1], str) else state_msgs[0][1]
    assert state_doc["kind"] == "app_state"
    assert "occupancy" in state_doc
    assert "appliances" in state_doc
    assert "fan_1" in state_doc["appliances"]
