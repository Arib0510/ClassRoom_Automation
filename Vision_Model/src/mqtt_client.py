"""MQTT 3.1.1 state snapshots, process availability, and explicit freshness leases."""

from __future__ import annotations

import json
import logging
import math
import os
import threading
from datetime import UTC, datetime
from typing import Any

from .config import MQTTConfig
from .zones import ZONE_IDS

LOG = logging.getLogger(__name__)


def encode_json(data: dict) -> str:
    return json.dumps(data, separators=(",", ":"), sort_keys=True, allow_nan=False)


def build_payload(
    *,
    device_id: str,
    boot_id: str,
    sequence: int,
    zones: dict[str, dict],
    now: float,
    unix_time: float,
    last_observation: float | None,
    stale_seconds: float,
    expiry_seconds: int,
) -> dict:
    """Pure serialization boundary, shared by live service and offline simulation."""
    if not math.isfinite(now) or not math.isfinite(unix_time):
        raise ValueError("Payload clocks must be finite")
    if not device_id or not boot_id or type(sequence) is not int or sequence < 0:
        raise ValueError("Payload requires device ID, boot ID, and nonnegative sequence")
    if set(zones) != set(ZONE_IDS):
        raise ValueError("Payload must include exactly the four physical quadrants")
    for entry in zones.values():
        if set(entry) != {"state", "person_count", "last_seen_age_ms"}:
            raise ValueError("Invalid zone payload fields")
        if entry["state"] not in ("unknown", "occupied", "vacant"):
            raise ValueError("Invalid occupancy state")
        for key in ("person_count", "last_seen_age_ms"):
            value = entry[key]
            if value is not None and (type(value) is not int or value < 0):
                raise ValueError(f"{key} must be null or a nonnegative integer")
    age = None if last_observation is None else now - last_observation
    if age is not None and (not math.isfinite(age) or age < 0):
        raise ValueError("Observation timestamp cannot be nonfinite or in the future")
    if age is None or age > stale_seconds:
        zones = {
            key: {"state": "unknown", "person_count": None, "last_seen_age_ms": None}
            for key in ZONE_IDS
        }
    lease = expiry_seconds if age is None else min(expiry_seconds, max(0.0, stale_seconds - age))
    # UTC must be synchronized on the Pi and controllers; receiver watchdog is also required.
    return {
        "schema_version": 1,
        "device_id": device_id,
        "boot_id": boot_id,
        "sequence": sequence,
        "sent_at": datetime.fromtimestamp(unix_time, UTC).isoformat(timespec="milliseconds"),
        "sent_at_unix_ms": int(unix_time * 1000),
        "expires_at_unix_ms": int((unix_time + lease) * 1000),
        "observation_age_ms": None if age is None else round(age * 1000),
        "zones": zones,
    }


class MQTTPublisher:
    def __init__(self, config: MQTTConfig, device_id: str, boot_id: str, client: Any = None):
        from paho.mqtt import client as mqtt

        self.config = config
        self.device_id = device_id
        self.boot_id = boot_id
        self.client = (
            client
            if client is not None
            else mqtt.Client(
                callback_api_version=mqtt.CallbackAPIVersion.VERSION2,
                client_id=config.client_id,
                clean_session=True,
                protocol=mqtt.MQTTv311,
            )
        )
        self._connected = threading.Event()
        self._refresh = threading.Event()
        self._pending = None
        self._started = False
        self.client.on_connect = self._on_connect
        self.client.on_disconnect = self._on_disconnect
        self.client.reconnect_delay_set(min_delay=1, max_delay=10)
        self.client.max_inflight_messages_set(1)
        self.client.max_queued_messages_set(2)
        username = os.environ.get(config.username_env)
        password = os.environ.get(config.password_env)
        if password and not username:
            raise ValueError("MQTT password is set without a username")
        if username:
            self.client.username_pw_set(username, password)
        if config.tls:
            self.client.tls_set(ca_certs=str(config.ca_path) if config.ca_path else None)
        self.client.will_set(self.availability_topic, self._availability(False), qos=1, retain=True)

    @property
    def state_topic(self) -> str:
        return f"{self.config.topic_prefix}/state"

    @property
    def availability_topic(self) -> str:
        return f"{self.config.topic_prefix}/availability"

    @property
    def needs_refresh(self) -> bool:
        return self._refresh.is_set()

    def _availability(self, online: bool) -> str:
        return encode_json(
            {
                "schema_version": 1,
                "device_id": self.device_id,
                "boot_id": self.boot_id,
                "online": online,
            }
        )

    def _on_connect(self, client, userdata, flags, reason_code, properties) -> None:
        if reason_code != 0:
            LOG.warning("MQTT connection rejected: %s", reason_code)
            return
        self._connected.set()
        self._refresh.set()
        self._pending = None
        client.publish(self.availability_topic, self._availability(True), qos=1, retain=True)
        LOG.info("MQTT connected")

    def _on_disconnect(self, client, userdata, flags, reason_code, properties) -> None:
        self._connected.clear()
        LOG.warning("MQTT disconnected: %s", reason_code)

    def start(self) -> None:
        self.client.connect_async(self.config.host, self.config.port, self.config.keepalive)
        self.client.loop_start()
        self._started = True

    def publish(self, payload: dict) -> bool:
        # QoS 0 telemetry is nonretained and never queued while disconnected.
        # Only one unsent telemetry packet is allowed; heartbeat retries current state.
        if not self._connected.is_set():
            return False
        if self._pending is not None and not self._pending.is_published():
            return False
        info = self.client.publish(self.state_topic, encode_json(payload), qos=0, retain=False)
        if info.rc != 0:
            self._pending = None
            return False
        self._pending = info
        self._refresh.clear()
        return True

    def close(self) -> None:
        if not self._started:
            return
        try:
            if self._connected.is_set():
                info = self.client.publish(
                    self.availability_topic, self._availability(False), qos=1, retain=True
                )
                info.wait_for_publish(timeout=1.0)
            self.client.disconnect()
        finally:
            self.client.loop_stop()
            self._connected.clear()
            self._started = False
