#!/usr/bin/env python3
"""Authenticated MQTT round-trip on a unique diagnostics topic; never sends commands."""
from __future__ import annotations

import json
import os
import threading
import time
import uuid

import paho.mqtt.client as mqtt


def main() -> int:
    host = os.environ.get("CLASSROOM_MQTT_HOST", "10.247.68.155")
    username = os.environ.get("CLASSROOM_MQTT_USERNAME")
    password = os.environ.get("CLASSROOM_MQTT_PASSWORD")
    if username != "pi-vision" or not password:
        raise SystemExit("Set CLASSROOM_MQTT_USERNAME=pi-vision and its password privately.")

    token = uuid.uuid4().hex
    topic = f"classpulse/reb_room_301/diagnostics/non_actuating/{token}"
    connected, subscribed, echoed = (threading.Event() for _ in range(3))
    failures: list[str] = []
    client = mqtt.Client(
        callback_api_version=mqtt.CallbackAPIVersion.VERSION2,
        client_id=f"pi-vision-probe-{token[:10]}",
        protocol=mqtt.MQTTv311,
    )
    client.username_pw_set(username, password)
    client.reconnect_delay_set(min_delay=1, max_delay=10)

    def on_connect(client, userdata, flags, reason_code, properties):
        if reason_code == 0:
            connected.set()
            client.subscribe(topic, qos=0)
        else:
            failures.append(f"connection rejected: {reason_code}")

    def on_subscribe(client, userdata, mid, reason_codes, properties):
        if reason_codes and any(code.is_failure for code in reason_codes):
            failures.append("diagnostics subscription rejected by ACL")
        else:
            subscribed.set()

    def on_message(client, userdata, message):
        if message.topic == topic and message.payload == token.encode() and not message.retain:
            echoed.set()

    client.on_connect = on_connect
    client.on_subscribe = on_subscribe
    client.on_message = on_message
    try:
        client.connect(host, 1883, keepalive=20)
        client.loop_start()
        if not connected.wait(6):
            raise TimeoutError("MQTT authentication/connect timed out")
        if not subscribed.wait(4):
            raise TimeoutError("MQTT diagnostics subscription timed out")
        info = client.publish(topic, token, qos=0, retain=False)
        if info.rc != mqtt.MQTT_ERR_SUCCESS:
            raise RuntimeError(f"MQTT publish failed: {info.rc}")
        info.wait_for_publish(timeout=4)
        if not echoed.wait(4):
            raise TimeoutError("MQTT diagnostics echo timed out")
        print(f"PASS authenticated non-actuating MQTT round-trip via {host}:1883")
        print("PASS unique diagnostics topic, QoS 0, retain=false; no appliance topics used")
        print("INFO Observe app/state and controller status separately during DRY_RUN launch.")
        return 0
    finally:
        if client.is_connected():
            client.disconnect()
        client.loop_stop()


if __name__ == "__main__":
    raise SystemExit(main())
