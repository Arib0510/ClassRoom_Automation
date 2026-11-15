"""Unit tests for Smart Classroom AC Control (`src/ac_control.py`)."""

import json

import pytest

from src.ac_control import ClassroomACController


def test_ac_turns_on_after_occupancy_delay_and_scales_temp():
    published = []
    ctrl = ClassroomACController(
        room_id="reb_room_301",
        enter_delay_sec=2.0,
        vacant_off_delay_sec=15.0,
        min_command_interval_sec=0.0,
    )

    # t=0.0: 3 students enter Zone 1 -> still waiting for enter_delay_sec
    u1 = ctrl.evaluate_zone(1, occupant_count=3, now=0.0, publish_fn=lambda t, p: published.append((t, p)), operation_mode="LIVE")
    assert u1.is_on is False
    assert len(published) == 0

    # t=2.5: 3 students still present -> AC turns ON at 25°C (Eco 1-5 group)
    u1 = ctrl.evaluate_zone(1, occupant_count=3, now=2.5, publish_fn=lambda t, p: published.append((t, p)), operation_mode="LIVE")
    assert u1.is_on is True
    assert u1.temperature == 25
    assert u1.fan_speed == 1
    assert any(t == "ruet/classroom/reb_room_301/zone/1/ac/command" for t, _ in published)

    # Verify JSON wire format matches ESP32 handleAcCommand()
    ac_msg = next(json.loads(p) for t, p in published if t == "ruet/classroom/reb_room_301/zone/1/ac/command")
    assert ac_msg["state"] == "ON"
    assert ac_msg["temp"] == 25
    assert ac_msg["mode"] == "COOL"
    assert ac_msg["gpio"] == 4
    assert ac_msg["protocol"] == "GREE"

    # Crowd increases to 20 students -> adaptive setpoint lowers to 22°C, Fan 3, Swing ON
    published.clear()
    u1 = ctrl.evaluate_zone(1, occupant_count=20, now=10.0, publish_fn=lambda t, p: published.append((t, p)), operation_mode="LIVE")
    assert u1.is_on is True
    assert u1.temperature == 22
    assert u1.fan_speed == 3
    assert u1.swing is True


def test_ac_turns_off_after_vacancy_delay():
    published = []
    ctrl = ClassroomACController(
        room_id="reb_room_301",
        enter_delay_sec=0.0,
        vacant_off_delay_sec=10.0,
        min_command_interval_sec=0.0,
    )

    ctrl.evaluate_zone(1, occupant_count=8, now=0.0, publish_fn=lambda t, p: published.append((t, p)), operation_mode="LIVE")
    assert ctrl.units[1].is_on is True
    published.clear()

    # Brief vacancy at t=5.0s (< 10.0s delay) -> AC remains ON (anti-short-cycle)
    ctrl.evaluate_zone(1, occupant_count=0, now=5.0, publish_fn=lambda t, p: published.append((t, p)), operation_mode="LIVE")
    assert ctrl.units[1].is_on is True
    assert len(published) == 0

    # Continuous vacancy at t=11.0s (>= 10.0s delay) -> AC turns OFF
    ctrl.evaluate_zone(1, occupant_count=0, now=11.0, publish_fn=lambda t, p: published.append((t, p)), operation_mode="LIVE")
    assert ctrl.units[1].is_on is False
    ac_msg = next(json.loads(p) for t, p in published if t == "ruet/classroom/reb_room_301/zone/1/ac/command")
    assert ac_msg["state"] == "OFF"


def test_ac_vision_gate_blocks_manual_on_when_empty_and_isolates_dry_run():
    published = []
    ctrl = ClassroomACController(room_id="reb_room_301", min_command_interval_sec=0.0)

    # Attempt manual ON when 0 occupants -> REJECTED by Vision Gate
    accepted, reason = ctrl.handle_app_ac_request(
        zone_id=1,
        occupant_count=0,
        desired_state="ON",
        temp=20,
        now=1.0,
        publish_fn=lambda t, p: published.append((t, p)),
        operation_mode="DRY_RUN",
    )
    assert accepted is False
    assert "empty" in reason.lower()
    assert ctrl.units[1].is_on is False
    # Verify DRY_RUN never publishes to live ruet/classroom/... topics
    assert all(not t.startswith("ruet/classroom/") for t, _ in published)
    assert any(t.endswith("/dry_run/command") for t, _ in published)
