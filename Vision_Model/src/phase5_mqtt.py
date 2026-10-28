"""Real Paho MQTT 3.1.1 transport with bounded receive/outgoing queues; no vision logic."""

from __future__ import annotations

import json
import os
import threading
import time
from collections import deque


class MQTTTransport:
    def __init__(self, config, session_id, client=None):
        from paho.mqtt import client as mqtt

        self.config, self.session_id = config, session_id
        self.connected = False
        self.generation = 0
        self.received = deque(maxlen=128)
        self.lock = threading.Lock()
        self.dropped_received = 0
        self.reconnects = 0
        self.pending = None
        self.started = False
        self.interlock = None
        self.clock_check = lambda: False
        self.last_publish_seconds = None
        broker = config.base.mqtt
        self.client = client or mqtt.Client(
            mqtt.CallbackAPIVersion.VERSION2,
            client_id=broker.client_id + "-p5-" + session_id[:8],
            clean_session=True,
            protocol=mqtt.MQTTv311,
        )
        self.client.reconnect_delay_set(min_delay=1, max_delay=10)
        self.client.max_inflight_messages_set(1)
        self.client.max_queued_messages_set(2)
        username, password = os.getenv(broker.username_env), os.getenv(broker.password_env)
        if password and not username:
            raise ValueError("MQTT password without username")
        if username:
            self.client.username_pw_set(username, password)
        if broker.tls:
            self.client.tls_set(ca_certs=str(broker.ca_path) if broker.ca_path else None)
        self.client.on_connect, self.client.on_disconnect = self._connect, self._disconnect
        self.client.on_message = self._message
        self.client.will_set(self.presence_topic, self.presence(False), qos=1, retain=True)

    @property
    def presence_topic(self):
        return self.config.data["mqtt"]["prefix"] + "/pi/availability"

    def presence(self, online):
        return json.dumps({"schema_version": 1, "session_id": self.session_id, "online": online})

    def _connect(self, client, userdata, flags, reason_code, properties):
        if reason_code != 0:
            return
        with self.lock:
            self.received.clear()
            self.pending = None
            self.generation += 1
            self.reconnects += 1
            self.connected = True
        prefix = self.config.data["mqtt"]["prefix"]
        for controller in self.config.data["controllers"]:
            for suffix in ("status", "ack"):
                client.subscribe(f"{prefix}/controllers/{controller['id']}/{suffix}", qos=1)
        client.publish(self.presence_topic, self.presence(True), qos=1, retain=True)

    def _disconnect(self, client, userdata, flags, reason_code, properties):
        with self.lock:
            self.connected = False
            self.received.clear()
            self.pending = None

    def _message(self, client, userdata, message):
        if len(message.payload) > 16_384:
            self.dropped_received += 1
            return
        with self.lock:
            if len(self.received) == self.received.maxlen:
                self.dropped_received += 1
            self.received.append((message.topic, bytes(message.payload), bool(message.retain)))

    def start(self):
        if not self.config.data["mqtt"]["enabled"]:
            raise ValueError("MQTT transport explicitly disabled")
        broker = self.config.base.mqtt
        self.client.connect_async(broker.host, broker.port, broker.keepalive)
        self.client.loop_start()
        self.started = True

    def bind_interlock(self, interlock, clock_check):
        from .phase5_safety import SafetyInterlock

        if not isinstance(interlock, SafetyInterlock) or interlock.session_id != self.session_id:
            raise ValueError("Real transport requires the matching session safety interlock")
        self.interlock, self.clock_check = interlock, clock_check

    def publish(self, topic, payload, qos=0):
        started = time.perf_counter()
        prefix = self.config.data["mqtt"]["prefix"]
        if not topic.startswith(prefix + "/") or qos not in (0, 1):
            raise ValueError("Invalid topic/QoS")
        if topic.endswith("/command") or payload.get("kind") == "command":
            from .phase5_protocol import validate_command

            inventory = {a["id"]: a for a in self.config.data["appliances"]}
            validate_command(payload, inventory, time.time())
            suffix = "dry_run/command" if self.config.mode == "DRY_RUN" else "command"
            expected = f"{prefix}/controllers/{payload['controller_id']}/{suffix}"
            if (
                self.config.mode == "OBSERVE"
                or payload["mode"] != self.config.mode
                or topic != expected
                or payload["session_id"] != self.session_id
                or self.interlock is None
                or not self.clock_check()
                or not self.interlock.permits(
                    inventory[payload["appliance_id"]], time.monotonic(), time.time()
                )[0]
            ):
                raise ValueError("Command rejected by mode, route or session safety interlock")
        if not self.connected or self.pending is not None and not self.pending.is_published():
            return False
        encoded = json.dumps(payload, allow_nan=False, separators=(",", ":"))
        if len(encoded.encode()) > 16_384:
            raise ValueError("Outgoing MQTT payload exceeds bound")
        info = self.client.publish(topic, encoded, qos=qos, retain=False)
        if info.rc != 0:
            return False
        self.pending = info
        self.last_publish_seconds = time.perf_counter() - started
        return True

    def drain(self):
        with self.lock:
            result = list(self.received)
            self.received.clear()
        return result

    def close(self):
        if not self.started:
            return
        try:
            if self.connected:
                self.client.publish(
                    self.presence_topic, self.presence(False), qos=1, retain=True
                ).wait_for_publish(timeout=1)
            self.client.disconnect()
        finally:
            self.client.loop_stop()
            self.connected = False
            self.started = False


class MemoryTransport:
    """Bounded offline fake transport, incapable of network/GPIO access."""

    def __init__(self, connected=False):
        self.connected, self.generation = connected, 1
        self.sent = deque(maxlen=128)
        self.incoming = deque(maxlen=128)

    def publish(self, topic, payload, qos=0):
        if not self.connected:
            return False
        self.sent.append((topic, payload, qos, False))
        return True

    def drain(self):
        values = list(self.incoming)
        self.incoming.clear()
        return values

    def close(self):
        self.connected = False
