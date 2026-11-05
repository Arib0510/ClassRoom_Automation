"""Bridge between Flutter App manual requests/state telemetry and Phase 5 ApplianceEngine.

Wire contract:
  App -> Pi: P/app/requests
    {
      "request_id": "<uuid>",
      "appliance_id": "<id>",
      "desired_state": "ON" | "OFF" | "AUTO",
      "duration_seconds": 60.0,
      "operator": "flutter_app",
      "sent_at_unix_ms": 1700000000000
    }
  Pi -> App: P/app/results
    {
      "schema_version": 1,
      "kind": "app_result",
      "request_id": "<uuid>",
      "result": "ACCEPTED" | "REJECTED",
      "reason": "OK" | "<error_description>",
      "appliance_id": "<id>",
      "desired_state": "ON" | "OFF" | "AUTO",
      "event_time_unix_ms": 1700000000050
    }
  Pi -> App: P/app/state
    {
      "schema_version": 1,
      "kind": "app_state",
      "session_id": "<session_id>",
      "mode": "OBSERVE" | "DRY_RUN" | "LIVE_APPLIANCE",
      "sent_at_unix_ms": 1700000000000,
      "freshness_seconds": 4.0,
      "occupancy": { ... },
      "appliances": { ... }
    }
"""

from __future__ import annotations

import json
import math
import uuid
from typing import Any, Dict, Optional


class AppBridge:
    def __init__(self, engine, transport, prefix: str, session_id: str):
        self.engine = engine
        self.transport = transport
        self.prefix = prefix.rstrip("/")
        self.session_id = session_id
        self.last_state_publish = -math.inf

        # Register app request subscription topic
        self.request_topic = f"{self.prefix}/app/requests"
        self.result_topic = f"{self.prefix}/app/results"
        self.state_topic = f"{self.prefix}/app/state"

    def handle_request(self, payload: bytes | str, now: float, unix: float) -> Dict[str, Any]:
        """Validate and dispatch an ingress request from Flutter."""
        request_id = None
        appliance_id = None
        desired_state = None
        try:
            if isinstance(payload, bytes):
                payload = payload.decode("utf-8")
            data = json.loads(payload)
            if not isinstance(data, dict):
                raise ValueError("App request payload must be a JSON object")

            request_id = str(data.get("request_id", "")).strip()
            if not request_id:
                request_id = f"gen-{uuid.uuid4().hex[:12]}"

            appliance_id = str(data.get("appliance_id", "")).strip()
            if appliance_id not in self.engine.appliances:
                raise ValueError(f"Unknown appliance_id '{appliance_id}'")

            desired_state = str(data.get("desired_state", "")).strip().upper()
            if desired_state not in ("ON", "OFF", "AUTO"):
                raise ValueError("desired_state must be 'ON', 'OFF', or 'AUTO'")

            duration = float(data.get("duration_seconds", 60.0))
            if duration <= 0 or duration > 300:
                duration = min(max(duration, 1.0), 300.0)

            operator = str(data.get("operator", "flutter_app")).strip() or "flutter_app"

            # Apply override in ApplianceEngine
            if desired_state == "AUTO":
                self.engine.overrides.pop(appliance_id, None)
            else:
                expires_at = now + duration
                self.engine.override(appliance_id, desired_state, operator, expires_at, now)

            result_packet = {
                "schema_version": 1,
                "kind": "app_result",
                "request_id": request_id,
                "result": "ACCEPTED",
                "reason": "OK",
                "appliance_id": appliance_id,
                "desired_state": desired_state,
                "event_time_unix_ms": int(unix * 1000),
            }
            if self.transport.connected:
                self.transport.publish(self.result_topic, result_packet, qos=0)
            return result_packet

        except Exception as exc:
            err_packet = {
                "schema_version": 1,
                "kind": "app_result",
                "request_id": request_id or "invalid",
                "result": "REJECTED",
                "reason": str(exc),
                "appliance_id": appliance_id,
                "desired_state": desired_state,
                "event_time_unix_ms": int(unix * 1000),
            }
            if self.transport.connected:
                self.transport.publish(self.result_topic, err_packet, qos=0)
            return err_packet

    def publish_app_state(
        self, snapshot: Dict[str, Any], decisions: Dict[str, Any], now: float, unix: float, force: bool = False
    ) -> bool:
        """Publish full occupancy + appliance telemetry snapshot for Flutter room monitor."""
        if not self.transport.connected:
            return False

        # Throttle to max once per second unless forced
        if not force and now - self.last_state_publish < 1.0:
            return False

        appliance_telemetry = {}
        for aid in self.engine.appliances:
            astate = self.engine.states.get(aid, {})
            ovr = self.engine.overrides.get(aid)
            appliance_telemetry[aid] = {
                "reported": astate.get("reported", "UNKNOWN"),
                "desired": astate.get("desired"),
                "failure": astate.get("failure"),
                "reason": astate.get("reason", "idle"),
                "override": {
                    "state": ovr[0],
                    "operator": ovr[1],
                    "expires_in_seconds": max(0.0, round(ovr[2] - now, 1)),
                }
                if ovr
                else None,
            }

        state_packet = {
            "schema_version": 1,
            "kind": "app_state",
            "session_id": self.session_id,
            "mode": self.engine.config.mode,
            "sent_at_unix_ms": int(unix * 1000),
            "freshness_seconds": self.engine.config.base.occupancy.stale_seconds,
            "occupancy": snapshot,
            "appliances": appliance_telemetry,
        }

        success = self.transport.publish(self.state_topic, state_packet, qos=0)
        if success:
            self.last_state_publish = now
        return success

