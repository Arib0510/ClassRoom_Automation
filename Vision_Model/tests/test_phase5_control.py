"""Synthetic clocks/controllers/evidence only. No ESP32, GPIO, broker or electrical validation."""

import copy
import json
from pathlib import Path

import pytest
import yaml

from src.calibration import CHECKS, geometry_digest, new_document
from src.phase5_config import digest, load_phase5
from src.phase5_control import ApplianceEngine
from src.phase5_mqtt import MemoryTransport
from src.phase5_occupancy import PhysicalMapper, TemporalOccupancy, ZoneEvidence, unknown
from src.phase5_protocol import ReferenceController, decode, validate_command
from src.phase5_safety import (
    APPLIANCE_CHECKS,
    TEST_CHECKS,
    OperatorGrant,
    SafetyInterlock,
    authorization_template,
)
from src.zones import ZONE_IDS


@pytest.fixture
def phase5_factory(tmp_path):
    count = 0

    def create(mode="DRY_RUN", commissioned=False):
        nonlocal count
        count += 1
        folder = tmp_path / str(count)
        folder.mkdir()
        data = yaml.safe_load(Path("config/phase5.example.yaml").read_text())
        data["base_config"] = str(Path("config/config.yaml").resolve())
        data["mode"] = mode
        data["mqtt"].update(enabled=False, prefix="test-only/phase5", ack_timeout_seconds=0.5)
        evidence = folder / "firmware-evidence.txt"
        evidence.write_text("SYNTHETIC software fixture; no physical approval")
        data["controllers"] = [
            {
                "id": "board_a",
                "protocol": "classroom-control-v1",
                "firmware_sha256": "a" * 64,
                "verified": True,
                "evidence": str(evidence),
                "dry_run_enforced": True,
                "local_fault_policy": "HOLD: synthetic fixture",
            }
        ]
        data["appliances"] = [
            {
                "id": "indicator",
                "zone": "front_left",
                "controller": "board_a",
                "channel": "test_indicator",
                "ownership_verified": True,
                "test_output_isolated": True,
                "off_delay_seconds": 0,
            }
        ]
        if commissioned:
            ref = {
                "file_name": "synthetic.png",
                "sha256": "b" * 64,
                "width": 640,
                "height": 480,
                "kind": "mounted_pi",
                "camera_id": data["camera"]["id"],
                "pose_id": data["camera"]["pose_id"],
                "hflip": False,
                "vflip": False,
            }
            geometry = new_document(ref)
            geometry["seating_rows"] = [
                {"id": "row", "image_points": [[0.1, 0.1], [0.9, 0.1]], "notes": "synthetic"}
            ]
            polygons = [
                [[0.05, 0.05], [0.45, 0.05], [0.45, 0.45], [0.05, 0.45]],
                [[0.55, 0.05], [0.95, 0.05], [0.95, 0.45], [0.55, 0.45]],
                [[0.05, 0.55], [0.45, 0.55], [0.45, 0.95], [0.05, 0.95]],
                [[0.55, 0.55], [0.95, 0.55], [0.95, 0.95], [0.55, 0.95]],
            ]
            geometry["seat_regions"] = [
                {"id": z, "row_id": "row", "zone_id": z, "polygon": p, "floor_point": None}
                for z, p in zip(ZONE_IDS, polygons, strict=True)
            ]
            geometry["calibrated"] = True
            geometry["confirmation"] = {
                "reviewer": "synthetic unit fixture",
                "confirmed_at": "2026-01-01T00:00:00+00:00",
                "geometry_digest": geometry_digest(geometry),
                "checks": dict.fromkeys(CHECKS, True),
            }
            geometry_path = folder / "geometry.json"
            geometry_path.write_text(json.dumps(geometry))
            commissioning = {
                "schema_version": 1,
                "calibration_file": "geometry.json",
                "calibration_sha256": digest(geometry_path),
                "calibration_version": 0,
                "verified": True,
                "reviewer": "synthetic unit fixture",
                "verified_at": "2026-01-01T00:00:00+00:00",
                "evidence": "synthetic only",
                "camera": {
                    **data["camera"],
                    "width": 640,
                    "height": 480,
                    "hflip": False,
                    "vflip": False,
                },
                "vacancy_coverage_verified": dict.fromkeys(ZONE_IDS, True),
            }
            commissioning["camera"].pop("restart_attempts")
            (folder / "commissioning.json").write_text(json.dumps(commissioning))
            data["commissioning"] = "commissioning.json"
        data["authorization"] = "authorization.json"
        path = folder / "phase5.yaml"
        path.write_text(yaml.safe_dump(data))
        cfg = load_phase5(path)
        return cfg

    return create


@pytest.fixture
def board_system(phase5_factory):
    cfg = phase5_factory()
    transport = MemoryTransport(True)
    gate = SafetyInterlock(cfg, PhysicalMapper(cfg), "session")
    index = 0

    def token():
        nonlocal index
        index += 1
        return f"token{index}"

    engine = ApplianceEngine(cfg, transport, gate, "session", clock_valid=True, token=token)
    board = ReferenceController("board_a", "boot1", engine.appliances)
    return cfg, transport, engine, board


def snapshot(now, state="OCCUPIED"):
    return {
        z: {"state": state, "observed_at": now if state != "UNKNOWN" else None} for z in ZONE_IDS
    }


def feedback(transport, packet):
    transport.incoming.append(
        (
            f"test-only/phase5/controllers/board_a/{packet['kind']}",
            json.dumps(packet).encode(),
            False,
        )
    )


def handshake(system, now=0, unix=1_800_000_000):
    cfg, transport, engine, board = system
    engine.step(snapshot(now), now, unix)
    hello = next(p for topic, p, _, _ in transport.sent if topic.endswith("/hello"))
    feedback(transport, board.hello(hello, unix))
    engine.step(snapshot(now + 0.01), now + 0.01, unix + 0.01)
    return next(p for topic, p, _, _ in transport.sent if topic.endswith("/command"))


def test_confirmed_occupancy_generates_idempotent_dry_command_and_ack(board_system):
    cfg, transport, engine, board = board_system
    command = handshake(board_system)
    assert command["mode"] == "DRY_RUN" and command["desired_state"] == "ON"
    assert command["expires_at_unix_ms"] - command["sent_at_unix_ms"] <= 3000
    ack = board.command(command, 0.02, 1_800_000_000.02, dry_topic=True)
    feedback(transport, ack)
    result = engine.step(snapshot(0.03), 0.03, 1_800_000_000.03)
    assert result["indicator"]["pending_command_id"] is None
    assert board.outputs["indicator"] == result["indicator"]["reported"] == "UNKNOWN"
    assert engine.counters["acknowledgements"] == 1
    assert all(retain is False for _, _, _, retain in transport.sent)


def test_unknown_stale_or_disconnected_never_renew_commands(board_system):
    cfg, transport, engine, board = board_system
    handshake(board_system)
    before = engine.counters["published"]
    result = engine.step(snapshot(0.1, "UNKNOWN"), 0.1, 1_800_000_000.1)
    assert result["indicator"]["desired"] is None
    engine.step(snapshot(0.1), 4.2, 1_800_000_004.2)
    assert engine.counters["published"] == before
    transport.connected = False
    result = engine.step(snapshot(4.3), 4.3, 1_800_000_004.3)
    assert result["indicator"]["reported"] == "UNKNOWN"
    assert result["indicator"]["pending_command_id"] is None


@pytest.mark.parametrize(
    "mutation",
    [
        "retained",
        "expired",
        "session",
        "challenge",
        "boot",
        "command",
        "sequence",
        "topic",
        "actual",
    ],
)
def test_bad_ack_cannot_reconcile_physical_state(board_system, mutation):
    cfg, transport, engine, board = board_system
    command = handshake(board_system)
    ack = board.command(command, 0.02, 1_800_000_000.02, dry_topic=True)
    topic = "test-only/phase5/controllers/board_a/ack"
    retained = False
    if mutation == "retained":
        retained = True
    if mutation == "expired":
        ack["expires_at_unix_ms"] = 0
    if mutation == "session":
        ack["session_id"] = "old"
    if mutation == "challenge":
        ack["challenge"] = "old"
    if mutation == "boot":
        ack["controller_boot_id"] = "old"
    if mutation == "command":
        ack["command_id"] = "old"
    if mutation == "sequence":
        ack["sequence"] = 0
    if mutation == "topic":
        topic = "wrong/topic"
    if mutation == "actual":
        ack["actual_state"] = "INVALID"
    assert engine.receive(topic, json.dumps(ack), retained, 0.03, 1_800_000_000.03) is False
    assert engine.counters["acknowledgements"] == 0


def test_ack_timeout_latches_and_operator_clear_is_explicit(board_system):
    cfg, transport, engine, board = board_system
    first = handshake(board_system)
    engine.step(snapshot(0.6), 0.6, 1_800_000_000.6)
    commands = [p for topic, p, _, _ in transport.sent if topic.endswith("/command")]
    assert len(commands) == 2 and commands[0] == commands[1] == first
    result = engine.step(snapshot(1.2), 1.2, 1_800_000_001.2)
    assert result["indicator"]["failure"] == "acknowledgement_timeout"
    engine.step(snapshot(1.8), 1.8, 1_800_000_001.8)
    assert engine.counters["published"] == 2
    engine.clear_fault("indicator", "tester")
    engine.step(snapshot(2), 2, 1_800_000_002)
    assert engine.counters["published"] == 3


def test_reconnect_and_reboot_require_new_binding(board_system):
    cfg, transport, engine, board = board_system
    command = handshake(board_system)
    ack = board.command(command, 0.02, 1_800_000_000.02, dry_topic=True)
    transport.connected = False
    engine.step(snapshot(0.1), 0.1, 1_800_000_000.1)
    transport.connected = True
    transport.generation += 1
    engine.step(snapshot(0.2), 0.2, 1_800_000_000.2)
    assert (
        engine.receive(
            "test-only/phase5/controllers/board_a/ack", json.dumps(ack), False, 0.2, 1_800_000_000.2
        )
        is False
    )
    current = engine.controllers["board_a"]
    hello = [p for topic, p, _, _ in transport.sent if topic.endswith("/hello")][-1]
    feedback(transport, board.hello(hello, 1_800_000_000.2))
    engine.step(snapshot(0.3), 0.3, 1_800_000_000.3)
    board.boot = "boot2"
    feedback(transport, board.status(1_800_000_000.4))
    engine.step(snapshot(0.4), 0.4, 1_800_000_000.4)
    assert current["boot"] is None
    assert current["challenge"] != hello["challenge"]


def test_clock_correction_stops_commands(board_system):
    cfg, transport, engine, board = board_system
    handshake(board_system)
    engine.step(snapshot(0.1), 0.1, 1_800_000_010)
    assert engine.clock_valid is False
    assert not engine.controllers


def test_manual_override_expires_and_cannot_activate_unknown(board_system):
    cfg, transport, engine, board = board_system
    handshake(board_system)
    engine.override("indicator", "OFF", "tester", 1, 0.1)
    result = engine.step(snapshot(0.2), 0.2, 1_800_000_000.2)
    assert result["indicator"]["desired"] == "OFF"
    result = engine.step(snapshot(0.3, "UNKNOWN"), 0.3, 1_800_000_000.3)
    assert result["indicator"]["desired"] is None
    result = engine.step(snapshot(1.1), 1.1, 1_800_000_001.1)
    assert result["indicator"]["desired"] == "ON"


@pytest.mark.parametrize("mode", ["OBSERVE", "LIVE_TEST", "LIVE_APPLIANCE"])
def test_modes_fail_closed_without_real_evidence(phase5_factory, mode):
    cfg = phase5_factory(mode)
    gate = SafetyInterlock(cfg, PhysicalMapper(cfg), "session")
    assert gate.permits(cfg.data["appliances"][0], 1, 1_800_000_001)[0] is False


def approved_gate(cfg):
    mapper = PhysicalMapper(cfg)
    auth = authorization_template(cfg)
    auth.update(
        commissioning_sha256=mapper.commissioning_hash,
        mode=cfg.mode,
        operators=["tester"],
        expires_at="2030-01-01T00:00:00+00:00",
    )
    evidence = cfg.path.parent / "synthetic-evidence.txt"
    evidence.write_text("Synthetic test evidence; NOT an electrical or hardware approval")
    auth["checks"] = {
        key: {
            "verified": True,
            "reviewer": "synthetic tester",
            "verified_at": "2026-01-01T00:00:00+00:00",
            "evidence_file": evidence.name,
            "sha256": digest(evidence),
        }
        for key in TEST_CHECKS + APPLIANCE_CHECKS
    }
    cfg.relative(cfg.data["authorization"]).write_text(json.dumps(auth))
    return SafetyInterlock(
        cfg, mapper, "session", OperatorGrant("session", "tester", cfg.mode, 100)
    )


@pytest.mark.parametrize("check", TEST_CHECKS + APPLIANCE_CHECKS)
def test_every_live_appliance_evidence_gate_is_required(phase5_factory, check):
    cfg = phase5_factory("LIVE_APPLIANCE", True)
    gate = approved_gate(cfg)
    assert gate.permits(cfg.data["appliances"][0], 1, 1_800_000_001)[0] is True
    path = cfg.relative(cfg.data["authorization"])
    auth = json.loads(path.read_text())
    auth["checks"][check]["verified"] = False
    path.write_text(json.dumps(auth))
    assert gate.permits(cfg.data["appliances"][0], 1, 1_800_000_001)[0] is False


@pytest.mark.parametrize(
    "fault", ["grant", "expired_grant", "old_session", "hash", "evidence", "geometry", "config"]
)
def test_authorization_is_bound_and_never_survives_restart(phase5_factory, fault):
    cfg = phase5_factory("LIVE_APPLIANCE", True)
    gate = approved_gate(cfg)
    if fault == "grant":
        gate.grant = None
    if fault == "expired_grant":
        gate.grant = OperatorGrant("session", "tester", cfg.mode, 0.5)
    if fault == "old_session":
        gate.grant = OperatorGrant("retired", "tester", cfg.mode, 100)
    if fault == "hash":
        path = cfg.relative(cfg.data["authorization"])
        auth = json.loads(path.read_text())
        auth["config_fingerprint"] = "bad"
        path.write_text(json.dumps(auth))
    if fault == "evidence":
        (cfg.path.parent / "synthetic-evidence.txt").write_text("changed")
    if fault == "geometry":
        gate.mapper.geometry_path.write_text("{}")
    if fault == "config":
        cfg.path.write_text(cfg.path.read_text() + "\n# changed")
    assert gate.permits(cfg.data["appliances"][0], 1, 1_800_000_001)[0] is False


def test_receiver_duplicate_expiry_and_local_watchdog_policy(board_system):
    cfg, transport, engine, board = board_system
    command = handshake(board_system)
    board.mode = "LIVE_TEST"
    packet = dict(command, mode="LIVE_TEST")
    board.policy = "OFF"
    board.command(packet, 0.02, 1_800_000_000.02)
    assert board.outputs["indicator"] == "ON"
    deadline = board.leases["indicator"]
    board.command(packet, 0.3, 1_800_000_000.3)
    assert board.leases["indicator"] == deadline
    with pytest.raises(ValueError, match="changed payload"):
        board.command(
            dict(packet, desired_state="OFF", sequence=packet["sequence"] + 1),
            0.35,
            1_800_000_000.35,
        )
    board.hello(
        next(p for topic, p, _, _ in transport.sent if topic.endswith("/hello")), 1_800_000_000.3
    )
    with pytest.raises(ValueError):
        board.command(dict(packet, command_id="mutated"), 0.4, 1_800_000_000.4)
    board.tick(deadline)
    assert board.outputs["indicator"] == "OFF"
    with pytest.raises(ValueError):
        board.command(packet, 5, 1_800_000_005)


@pytest.mark.parametrize("policy,expected", [("HOLD", "ON"), ("OFF", "OFF"), ("ON", "ON")])
def test_local_fault_policy_is_explicit_not_universal_off(board_system, policy, expected):
    cfg, transport, engine, board = board_system
    board.outputs["indicator"] = "ON"
    board.policy = policy
    board.fault()
    assert board.outputs["indicator"] == expected


@pytest.mark.parametrize(
    "payload",
    [
        '{"protocol":"classroom-control-v1","x":NaN}',
        '{"protocol":"classroom-control-v1","x":1,"x":2}',
        "[]",
        "x" * 17000,
    ],
)
def test_protocol_parser_rejects_malformed_payloads(payload):
    with pytest.raises(ValueError):
        decode(payload)


def test_command_validation_rejects_unknown_channel(board_system):
    cfg, transport, engine, board = board_system
    packet = handshake(board_system)
    with pytest.raises(ValueError):
        validate_command(dict(packet, channel="unowned"), engine.appliances, 1_800_000_000.1)


def test_temporal_arrival_vacancy_unknown_and_recovery():
    from src.config import OccupancyConfig

    temporal = TemporalOccupancy(OccupancyConfig())

    def evidence(state):
        return {
            z: ZoneEvidence(state, 1 if state == "OCCUPIED" else 0, 0.8, "synthetic")
            for z in ZONE_IDS
        }

    temporal.update("a", 0, evidence("OCCUPIED"), 0)
    assert temporal.snapshot(0)["front_left"]["state"] == "UNKNOWN"
    temporal.update("a", 0, evidence("OCCUPIED"), 0.6)
    assert temporal.snapshot(0.6)["front_left"]["state"] == "UNKNOWN"
    temporal.update("b", 0.6, evidence("OCCUPIED"), 0.6)
    assert temporal.snapshot(0.6)["front_left"]["state"] == "OCCUPIED"
    for i in range(11):
        temporal.update(f"empty-{i}", 1 + i, evidence("VACANT"), 1 + i)
        assert temporal.snapshot(1 + i)["front_left"]["state"] == (
            "VACANT" if i == 10 else "OCCUPIED"
        )
    temporal.update("unknown", 12, unknown("camera_fault"), 12)
    assert temporal.snapshot(12)["front_left"]["state"] == "UNKNOWN"
    temporal.update("recover1", 13, evidence("OCCUPIED"), 13)
    temporal.update("recover2", 13.5, evidence("OCCUPIED"), 13.5)
    assert temporal.snapshot(13.5)["front_left"]["state"] == "OCCUPIED"
    assert temporal.snapshot(17.5)["front_left"]["state"] == "UNKNOWN"


def test_temporal_independent_zones_conflicts_and_old_frame_rejection():
    from src.config import OccupancyConfig

    temporal = TemporalOccupancy(OccupancyConfig())
    evidence = unknown("coverage")
    evidence["front_left"] = ZoneEvidence("OCCUPIED", 1, 0.8, "synthetic")
    temporal.update("first", 0, evidence, 0)
    temporal.update("second", 0.5, evidence, 0.5)
    assert temporal.snapshot(0.5)["front_left"]["state"] == "OCCUPIED"
    assert temporal.snapshot(0.5)["front_right"]["state"] == "UNKNOWN"
    assert temporal.update("old", 0.2, evidence, 0.6) is False
    assert temporal.update("stale", 1, evidence, 6) is False
    assert temporal.snapshot(6)["front_left"]["state"] == "UNKNOWN"
    with pytest.raises(ValueError):
        temporal.snapshot(5)


def test_mapper_requires_physical_verification_and_separate_vacancy_coverage(phase5_factory):
    from src.detector import Detection

    pending = PhysicalMapper(phase5_factory())
    assert {e.state for e in pending.map([], (640, 480)).values()} == {"UNKNOWN"}
    mapper = PhysicalMapper(phase5_factory(commissioned=True))
    assert {e.state for e in mapper.map([], (640, 480)).values()} == {"VACANT"}
    mapper.document["vacancy_coverage_verified"]["front_right"] = False
    result = mapper.map([Detection((0.1, 0.1, 0.3, 0.3), 0.8, 0)], (640, 480))
    assert result["front_left"].state == "OCCUPIED" and result["front_right"].state == "UNKNOWN"
    # Synthetic geometry only: anchor on an unmapped boundary cannot become vacancy.
    assert {
        e.state
        for e in mapper.map([Detection((0.45, 0.45, 0.55, 0.55), 0.8, 0)], (640, 480)).values()
    } == {"UNKNOWN"}
    assert {e.state for e in mapper.map([], (640, 480), image_usable=False).values()} == {"UNKNOWN"}


@pytest.mark.parametrize(
    "section,key,value",
    [
        ("camera", "rotation", 45),
        ("strategy", "mode", "YOLO"),
        ("strategy", "allow_multipass", "true"),
        ("resources", "max_pipeline_seconds", 5),
        ("mqtt", "lease_seconds", 9),
        ("mqtt", "command_qos", True),
        ("mqtt", "prefix", "unsafe/#"),
        ("logging", "backup_count", 0),
    ],
)
def test_bad_configuration_rejected_before_hardware(phase5_factory, section, key, value):
    cfg = phase5_factory()
    data = copy.deepcopy(cfg.data)
    data[section][key] = value
    cfg.path.write_text(yaml.safe_dump(data))
    with pytest.raises(ValueError):
        load_phase5(cfg.path)


def test_inventory_duplicate_channels_and_unverified_firmware(phase5_factory):
    cfg = phase5_factory()
    data = copy.deepcopy(cfg.data)
    data["appliances"].append(dict(data["appliances"][0], id="duplicate_channel"))
    cfg.path.write_text(yaml.safe_dump(data))
    with pytest.raises(ValueError):
        load_phase5(cfg.path)
    cfg = phase5_factory()
    cfg.data["controllers"][0]["verified"] = False
    gate = SafetyInterlock(cfg, PhysicalMapper(cfg), "session")
    assert gate.permits(cfg.data["appliances"][0], 0, 1_800_000_000)[0] is False


def test_extra_off_delay_and_rate_limit_are_independent(board_system):
    cfg, transport, engine, board = board_system
    command = handshake(board_system)
    feedback(transport, board.command(command, 0.02, 1_800_000_000.02, dry_topic=True))
    engine.step(snapshot(0.03), 0.03, 1_800_000_000.03)
    cfg.data["appliances"][0]["off_delay_seconds"] = 1
    result = engine.step(snapshot(0.1, "VACANT"), 0.1, 1_800_000_000.1)
    assert result["indicator"]["desired"] is None
    result = engine.step(snapshot(1, "VACANT"), 1, 1_800_000_001)
    assert result["indicator"]["desired"] is None
    result = engine.step(snapshot(1.11, "VACANT"), 1.11, 1_800_000_001.11)
    assert result["indicator"]["desired"] == "OFF"
    published = engine.counters["published"]
    engine.step(snapshot(1.2), 1.2, 1_800_000_001.2)
    assert engine.counters["published"] == published


def test_multiple_appliances_and_controller_ownership_are_independent(phase5_factory):
    cfg = phase5_factory()
    cfg.data["controllers"].append(dict(cfg.data["controllers"][0], id="board_b"))
    cfg.data["appliances"] += [
        dict(cfg.data["appliances"][0], id="lamp_two", channel="another_indicator"),
        dict(cfg.data["appliances"][0], id="back_lamp", zone="back_right", controller="board_b"),
    ]
    engine = ApplianceEngine(
        cfg, MemoryTransport(), SafetyInterlock(cfg, PhysicalMapper(cfg), "session"), "session"
    )
    zones = snapshot(0, "VACANT")
    zones["front_left"]["state"] = "OCCUPIED"
    states = engine.step(zones, 0, 1_800_000_000)
    assert states["indicator"]["desired"] == states["lamp_two"]["desired"] == "ON"
    assert states["back_lamp"]["desired"] == "OFF"


def test_live_test_reported_output_disagreement_is_latched(phase5_factory):
    cfg = phase5_factory("LIVE_TEST", True)
    transport = MemoryTransport(True)
    engine = ApplianceEngine(cfg, transport, approved_gate(cfg), "session", clock_valid=True)
    board = ReferenceController("board_a", "boot1", engine.appliances, mode="LIVE_TEST")
    command = handshake((cfg, transport, engine, board))
    ack = board.command(command, 0.02, 1_800_000_000.02)
    ack["actual_state"] = "OFF"
    feedback(transport, ack)
    states = engine.step(snapshot(0.03), 0.03, 1_800_000_000.03)
    assert states["indicator"]["failure"] == "output_disagrees_with_desired"
    assert engine.counters["acknowledgements"] == 0


def test_unenforced_dry_run_and_wrong_camera_pose_are_rejected(phase5_factory):
    cfg = phase5_factory()
    cfg.data["controllers"][0]["dry_run_enforced"] = False
    assert (
        SafetyInterlock(cfg, PhysicalMapper(cfg), "session").permits(
            cfg.data["appliances"][0], 0, 1_800_000_000
        )[0]
        is False
    )
    cfg = phase5_factory(commissioned=True)
    path = cfg.relative(cfg.data["commissioning"])
    document = json.loads(path.read_text())
    document["camera"]["pose_id"] = "different-pose"
    path.write_text(json.dumps(document))
    with pytest.raises(ValueError, match="pose"):
        PhysicalMapper(cfg)


def test_controller_reboot_history_cannot_grow_or_unlatch_on_reconnect(board_system):
    cfg, transport, engine, board = board_system
    handshake(board_system)
    controller = engine.controllers["board_a"]
    controller["retired_boots"] = {f"retired{i}" for i in range(16)}
    board.boot = "another-boot"
    packet = board.status(1_800_000_000.1)
    assert not engine.receive(
        "test-only/phase5/controllers/board_a/status",
        json.dumps(packet),
        False,
        0.1,
        1_800_000_000.1,
    )
    assert len(controller["retired_boots"]) == 16
    assert "board_a" in engine.controller_latches
    before = engine.counters["published"]
    transport.generation += 1
    engine.step(snapshot(0.2), 0.2, 1_800_000_000.2)
    assert engine.counters["published"] == before
    assert engine.controllers["board_a"]["boot"] is None
