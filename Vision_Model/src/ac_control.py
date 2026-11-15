"""Smart Classroom Air Conditioner (AC) Vision-Gated Controller.

Coordinates between the Raspberry Pi 5 Vision Model, the Flutter Mobile App,
and the ESP32 Optical IR Transmitter (Gree AC on GPIO 4, bypassing mechanical relays).

Key Features:
  • Vision-Gated AC Power Control:
      - Automatically turns AC ON when occupancy is confirmed (>= min_occupants).
      - Automatically turns AC OFF after continuous vacancy (vacant_off_delay_sec).
      - Blocks manual ON commands from the Flutter App or MQTT when the zone/room is empty (0 people).
  • Dynamic Crowd-Adaptive Temperature & Fan Scaling:
      - 1–5 occupants:   25°C, COOL, Fan 1 (Low)  — Eco cooling
      - 6–15 occupants:  24°C, COOL, Fan 2 (Med)  — Standard classroom cooling
      - 16+ occupants:   22°C, COOL, Fan 3 (High) — High thermal load cooling
  • Manual Override Lease Support:
      - Respects teacher/student temperature, mode, fan, and swing adjustments from the Flutter App
        while occupants are present, and automatically resets when the room empties.
  • Strict DRY_RUN Isolation:
      - Never transmits live IR MQTT packets (`ruet/classroom/.../ac/command`) when in DRY_RUN mode.
"""

from __future__ import annotations

import json
import logging
import time
from dataclasses import asdict, dataclass
from typing import Any, Callable, Dict, Optional, Tuple

LOG = logging.getLogger("ClassPulseAC")

VALID_AC_MODES = ("COOL", "AUTO", "DRY", "FAN", "HEAT")


@dataclass
class ACUnitState:
    zone_id: int
    board_id: str
    is_on: bool = False
    temperature: int = 24          # 16 - 30 °C
    mode: str = "COOL"             # COOL, AUTO, DRY, FAN, HEAT
    fan_speed: int = 0             # 0 = Auto, 1 = Low, 2 = Med, 3 = High
    swing: bool = False            # True = Auto Vertical Swing, False = Fixed Upward
    gpio_pin: int = 4              # ESP32 IR LED transmitter pin (GPIO 4)
    protocol: str = "GREE"
    manual_override: bool = False
    manual_override_state: Optional[str] = None  # "ON" or "OFF"
    override_expires_at: float = 0.0
    first_occupied_at: Optional[float] = None
    last_occupied_at: Optional[float] = None
    last_command_sent_at: float = 0.0

    def to_mqtt_payload(self, room_id: str) -> Dict[str, Any]:
        """Builds the exact JSON payload expected by ESP32 handleAcCommand()."""
        return {
            "room": room_id,
            "zone": self.zone_id,
            "board": self.zone_id,
            "controller_id": self.board_id,
            "type": "ac",
            "state": "ON" if self.is_on else "OFF",
            "temp": max(16, min(30, int(self.temperature))),
            "mode": self.mode.upper() if self.mode.upper() in VALID_AC_MODES else "COOL",
            "fan": max(0, min(3, int(self.fan_speed))),
            "swing": bool(self.swing),
            "gpio": self.gpio_pin,
            "protocol": self.protocol,
        }

    def to_status_dict(self) -> Dict[str, Any]:
        return {
            "zone_id": self.zone_id,
            "board_id": self.board_id,
            "state": "ON" if self.is_on else "OFF",
            "is_on": self.is_on,
            "temp": self.temperature,
            "mode": self.mode,
            "fan": self.fan_speed,
            "swing": self.swing,
            "gpio": self.gpio_pin,
            "protocol": self.protocol,
            "manual_override": self.manual_override,
        }


class ClassroomACController:
    """
    Vision-driven Air Conditioner controller for Zone 1 (Front/Near) and Zone 2 (Back/Far).
    Communicates with the ESP32 IR transmitter (`IRGreeAC` on GPIO 4).
    """

    def __init__(
        self,
        room_id: str = "reb_room_301",
        front_board_id: str = "board01",
        back_board_id: str = "board02",
        min_occupants_for_ac: int = 1,
        enter_delay_sec: float = 2.0,
        vacant_off_delay_sec: float = 30.0,
        min_command_interval_sec: float = 3.0,
        adaptive_temp: bool = True,
        default_temp: int = 24,
        default_mode: str = "COOL",
    ):
        self.room_id = room_id
        self.front_board_id = front_board_id
        self.back_board_id = back_board_id
        self.min_occupants_for_ac = max(1, int(min_occupants_for_ac))
        self.enter_delay_sec = max(0.0, float(enter_delay_sec))
        self.vacant_off_delay_sec = max(0.0, float(vacant_off_delay_sec))
        self.min_command_interval_sec = max(0.0, float(min_command_interval_sec))
        self.adaptive_temp = adaptive_temp
        self.default_temp = max(16, min(30, int(default_temp)))
        self.default_mode = default_mode.upper() if default_mode.upper() in VALID_AC_MODES else "COOL"

        self.units: Dict[int, ACUnitState] = {
            1: ACUnitState(zone_id=1, board_id=self.front_board_id, temperature=self.default_temp, mode=self.default_mode),
            2: ACUnitState(zone_id=2, board_id=self.back_board_id, temperature=self.default_temp, mode=self.default_mode),
        }

    @staticmethod
    def recommend_hvac_settings(occupant_count: int, default_temp: int = 24) -> Tuple[int, int, bool]:
        """
        Returns (target_temp_c, fan_speed_0_to_3, swing_bool) based on zone occupancy count.
        """
        if occupant_count <= 0:
            return (default_temp, 0, False)
        if occupant_count <= 5:
            return (25, 1, False)   # Small group: 25°C, Low fan, fixed louver
        if occupant_count <= 15:
            return (24, 2, True)    # Medium class: 24°C, Med fan, auto swing
        return (22, 3, True)        # Full class (16+): 22°C, High fan, auto swing

    def update_from_esp32_telemetry(
        self,
        zone_id: int,
        is_on: bool,
        temp: int = 24,
        mode: str = "COOL",
        fan: int = 0,
        swing: bool = False,
    ) -> None:
        """Synchronizes internal state with incoming ESP32 `/ac/status` telemetry."""
        unit = self.units.get(zone_id)
        if unit is None:
            return
        unit.is_on = bool(is_on)
        unit.temperature = max(16, min(30, int(temp)))
        if mode and mode.upper() in VALID_AC_MODES:
            unit.mode = mode.upper()
        unit.fan_speed = max(0, min(3, int(fan)))
        unit.swing = bool(swing)

    def handle_app_ac_request(
        self,
        zone_id: int,
        occupant_count: int,
        desired_state: str,
        temp: Optional[int] = None,
        mode: Optional[str] = None,
        fan: Optional[int] = None,
        swing: Optional[bool] = None,
        duration_seconds: float = 1800.0,
        now: Optional[float] = None,
        publish_fn: Optional[Callable[[str, str], None]] = None,
        operation_mode: str = "LIVE",
    ) -> Tuple[bool, str]:
        """
        Processes a manual AC control request from the Flutter App or MQTT.
        Enforces Vision Gate: AC cannot be turned ON if occupant_count <= 0.
        Returns (accepted: bool, reason: str).
        """
        now = time.monotonic() if now is None else float(now)
        unit = self.units.get(zone_id, self.units[1])
        req = desired_state.strip().upper()

        if req in ("ON", "1", "TRUE"):
            if occupant_count <= 0:
                unit.is_on = False
                unit.manual_override = False
                unit.manual_override_state = None
                self._dispatch_ac_command(unit, publish_fn, operation_mode, now, force=True)
                reason = f"Vision Gate: Zone {zone_id} is empty (0 occupants). AC cannot turn ON."
                LOG.warning(f"❄️ [AC VISION GATE BLOCKED] {reason}")
                return False, reason

            unit.is_on = True
            unit.manual_override = True
            unit.manual_override_state = "ON"
            unit.override_expires_at = now + max(60.0, float(duration_seconds))
            if temp is not None:
                unit.temperature = max(16, min(30, int(temp)))
            if mode is not None and mode.upper() in VALID_AC_MODES:
                unit.mode = mode.upper()
            if fan is not None:
                unit.fan_speed = max(0, min(3, int(fan)))
            if swing is not None:
                unit.swing = bool(swing)

            self._dispatch_ac_command(unit, publish_fn, operation_mode, now, force=True)
            return True, f"AC Zone {zone_id} ON ({unit.temperature}°C, {unit.mode})"

        if req in ("OFF", "0", "FALSE"):
            unit.is_on = False
            unit.manual_override = True
            unit.manual_override_state = "OFF"
            unit.override_expires_at = now + max(60.0, float(duration_seconds))
            self._dispatch_ac_command(unit, publish_fn, operation_mode, now, force=True)
            return True, f"AC Zone {zone_id} manually turned OFF"

        # AUTO mode clears manual override
        unit.manual_override = False
        unit.manual_override_state = None
        unit.override_expires_at = 0.0
        return True, f"AC Zone {zone_id} returned to Vision AUTO mode"

    def evaluate_zone(
        self,
        zone_id: int,
        occupant_count: int,
        now: Optional[float] = None,
        publish_fn: Optional[Callable[[str, str], None]] = None,
        operation_mode: str = "LIVE",
    ) -> ACUnitState:
        """
        Evaluates vision occupancy for a zone and triggers ESP32 IR AC transitions when needed.
        """
        now = time.monotonic() if now is None else float(now)
        unit = self.units.get(zone_id, self.units[1])

        # Expire manual override if lease ended
        if unit.manual_override and now >= unit.override_expires_at:
            unit.manual_override = False
            unit.manual_override_state = None

        is_occupied = occupant_count >= self.min_occupants_for_ac

        if is_occupied:
            unit.last_occupied_at = now
            if unit.first_occupied_at is None:
                unit.first_occupied_at = now

            # Respect active manual OFF override while occupied
            if unit.manual_override and unit.manual_override_state == "OFF":
                return unit

            occupied_duration = now - unit.first_occupied_at
            if occupied_duration >= self.enter_delay_sec:
                prev_on = unit.is_on
                prev_temp = unit.temperature
                prev_fan = unit.fan_speed

                unit.is_on = True
                if self.adaptive_temp and not (unit.manual_override and unit.manual_override_state == "ON"):
                    rec_temp, rec_fan, rec_swing = self.recommend_hvac_settings(occupant_count, self.default_temp)
                    unit.temperature = rec_temp
                    unit.fan_speed = rec_fan
                    unit.swing = rec_swing

                # Send IR command on state transition or significant crowd thermal change (>= 2°C)
                temp_shifted = abs(unit.temperature - prev_temp) >= 2
                if (not prev_on) or temp_shifted:
                    if (not prev_on) or (now - unit.last_command_sent_at >= self.min_command_interval_sec):
                        LOG.info(
                            f"❄️ [AC AUTO ON] Zone {zone_id} ({unit.board_id}): {occupant_count} people -> "
                            f"ON at {unit.temperature}°C ({unit.mode}, Fan {unit.fan_speed})"
                        )
                        self._dispatch_ac_command(unit, publish_fn, operation_mode, now, force=not prev_on)
        else:
            unit.first_occupied_at = None
            # If room empties, clear manual ON override after vacancy delay
            vacant_duration = (now - unit.last_occupied_at) if unit.last_occupied_at is not None else 999999.0
            if unit.is_on and vacant_duration >= self.vacant_off_delay_sec:
                unit.is_on = False
                unit.manual_override = False
                unit.manual_override_state = None
                LOG.info(
                    f"❄️ [AC AUTO OFF] Zone {zone_id} ({unit.board_id}) vacant for {vacant_duration:.1f}s -> Sending IR OFF"
                )
                self._dispatch_ac_command(unit, publish_fn, operation_mode, now, force=True)

        return unit

    def evaluate_all(
        self,
        front_count: int,
        back_count: int,
        now: Optional[float] = None,
        publish_fn: Optional[Callable[[str, str], None]] = None,
        operation_mode: str = "LIVE",
    ) -> Dict[int, ACUnitState]:
        now = time.monotonic() if now is None else float(now)
        self.evaluate_zone(1, front_count, now=now, publish_fn=publish_fn, operation_mode=operation_mode)
        self.evaluate_zone(2, back_count, now=now, publish_fn=publish_fn, operation_mode=operation_mode)
        return self.units

    def shutdown_all(
        self,
        publish_fn: Optional[Callable[[str, str], None]] = None,
        operation_mode: str = "LIVE",
    ) -> None:
        """Turns off all classroom AC units on shutdown (only transmits IR in LIVE mode)."""
        now = time.monotonic()
        for unit in self.units.values():
            unit.is_on = False
            self._dispatch_ac_command(unit, publish_fn, operation_mode, now, force=True)

    def _dispatch_ac_command(
        self,
        unit: ACUnitState,
        publish_fn: Optional[Callable[[str, str], None]],
        operation_mode: str,
        now: float,
        force: bool = False,
    ) -> None:
        if not force and (now - unit.last_command_sent_at) < self.min_command_interval_sec:
            return
        unit.last_command_sent_at = now

        if publish_fn is None:
            return

        payload_dict = unit.to_mqtt_payload(self.room_id)
        payload_json = json.dumps(payload_dict)

        # Phase 5 dry-run / live controller command packet
        phase5_topic = (
            f"classpulse/{self.room_id}/controllers/{unit.board_id}/dry_run/command"
            if operation_mode.upper() == "DRY_RUN"
            else f"classpulse/{self.room_id}/controllers/{unit.board_id}/command"
        )
        phase5_doc = {
            "protocol": "classroom-control-v1",
            "kind": "command",
            "controller_id": unit.board_id,
            "channel": "Channel AC",
            "appliance_id": f"ac_{unit.zone_id}",
            "desired_state": "ON" if unit.is_on else "OFF",
            "mode": operation_mode.upper(),
            "ac": payload_dict,
            "sent_at_unix_ms": int(time.time() * 1000),
        }
        publish_fn(phase5_topic, json.dumps(phase5_doc))

        # Strict DRY_RUN isolation: only publish to physical ESP32 IR topics in LIVE mode
        if operation_mode.upper() == "LIVE":
            publish_fn(f"ruet/classroom/{self.room_id}/zone/{unit.zone_id}/ac/command", payload_json)
            publish_fn(f"ruet/classroom/{self.room_id}/board/{unit.zone_id}/ac/command", payload_json)
            if unit.zone_id == 1:
                publish_fn(f"ruet/classroom/{self.room_id}/ac/command", payload_json)

    def get_app_state_appliances(self) -> Dict[str, Dict[str, Any]]:
        """Returns AC appliance states formatted for Flutter App `app_state` telemetry."""
        u1 = self.units[1]
        u2 = self.units[2]
        return {
            "ac_1": {
                "reported": "ON" if u1.is_on else "OFF",
                "desired": "ON" if u1.is_on else "OFF",
                "temp": u1.temperature,
                "mode": u1.mode,
                "fan": u1.fan_speed,
                "swing": u1.swing,
                "gpio": u1.gpio_pin,
                "protocol": u1.protocol,
            },
            "ac_2": {
                "reported": "ON" if u2.is_on else "OFF",
                "desired": "ON" if u2.is_on else "OFF",
                "temp": u2.temperature,
                "mode": u2.mode,
                "fan": u2.fan_speed,
                "swing": u2.swing,
                "gpio": u2.gpio_pin,
                "protocol": u2.protocol,
            },
        }
