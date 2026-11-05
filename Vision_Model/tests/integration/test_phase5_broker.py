"""Real loopback broker/Paho sockets, Python reference receiver; NO ESP32 or physical output."""

import json
import os
import socket
import subprocess
import sys
import threading
import time
import uuid
from dataclasses import replace
from pathlib import Path

import pytest
import test_phase5_control

from src.phase5_control import ApplianceEngine
from src.phase5_mqtt import MQTTTransport
from src.phase5_occupancy import PhysicalMapper
from src.phase5_protocol import ReferenceController
from src.phase5_safety import SafetyInterlock
from src.zones import ZONE_IDS

phase5_factory = test_phase5_control.phase5_factory
pytestmark = pytest.mark.skipif(
    os.getenv("PHASE5_REAL_BROKER_TEST") != "1", reason="Opt-in real loopback broker test; no ESP32"
)


def await_condition(condition, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return
        time.sleep(0.02)
    pytest.fail("Loopback condition timed out")


@pytest.fixture
def broker(tmp_path, request):
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    output = Path(os.getenv("PHASE5_BROKER_LOG_ROOT", str(tmp_path)))
    ready = output / f"ready-{uuid.uuid4().hex}.json"
    log = (output / f"{request.node.name}-{uuid.uuid4().hex}.log").open("w")
    child = subprocess.Popen(
        [
            sys.executable,
            "scripts/phase5_test_broker.py",
            "serve",
            "--port",
            str(port),
            "--ready",
            str(ready),
        ],
        stdout=log,
        stderr=subprocess.STDOUT,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    try:
        await_condition(ready.exists)
        assert json.loads(ready.read_text())["bind"] == "127.0.0.1"
        yield port, child
    finally:
        if child.poll() is None:
            child.terminate()
            child.wait(timeout=5)
        log.close()


def local_config(factory, port):
    cfg = factory("DRY_RUN")
    cfg.data["mqtt"].update(enabled=True, prefix="phase5-isolated-test/" + uuid.uuid4().hex)
    return replace(
        cfg, base=replace(cfg.base, mqtt=replace(cfg.base.mqtt, host="127.0.0.1", port=port))
    )


def test_real_publish_subscribe_command_ack_and_retained_feedback_rejection(broker, phase5_factory):
    from paho.mqtt import client as mqtt

    port, child = broker
    cfg = local_config(phase5_factory, port)
    transport = MQTTTransport(cfg, "broker-test-session")
    engine = ApplianceEngine(
        cfg,
        transport,
        SafetyInterlock(cfg, PhysicalMapper(cfg), "broker-test-session"),
        "broker-test-session",
        clock_valid=True,
    )
    reference = ReferenceController("board_a", "reference-boot", engine.appliances)
    prefix = cfg.data["mqtt"]["prefix"] + "/controllers/board_a"
    receiver = mqtt.Client(
        mqtt.CallbackAPIVersion.VERSION2, client_id="reference-" + uuid.uuid4().hex
    )
    subscribed = threading.Event()
    errors = []
    lock = threading.Lock()

    def on_connect(client, userdata, flags, reason_code, properties):
        assert reason_code == 0
        client.subscribe([(prefix + "/hello", 1), (prefix + "/dry_run/command", 1)])

    def on_subscribe(*args):
        subscribed.set()

    def on_message(client, userdata, message):
        try:
            packet = json.loads(message.payload)
            with lock:
                if message.topic.endswith("/hello"):
                    response = reference.hello(packet, time.time())
                else:
                    response = reference.command(
                        packet,
                        time.monotonic(),
                        time.time(),
                        retained=message.retain,
                        dry_topic=True,
                    )
            client.publish(
                prefix + "/" + response["kind"], json.dumps(response), qos=1, retain=False
            )
        except Exception as exc:
            errors.append(str(exc))

    receiver.on_connect, receiver.on_subscribe, receiver.on_message = (
        on_connect,
        on_subscribe,
        on_message,
    )
    receiver.connect("127.0.0.1", port, 10)
    receiver.loop_start()
    transport.start()
    try:
        await_condition(subscribed.is_set)
        await_condition(lambda: transport.connected)
        deadline = time.monotonic() + 8
        while engine.counters["acknowledgements"] < 1 and time.monotonic() < deadline:
            now = time.monotonic()
            engine.step(
                {z: {"state": "OCCUPIED", "observed_at": now} for z in ZONE_IDS}, now, time.time()
            )
            time.sleep(0.02)
        assert engine.counters["acknowledgements"] >= 1, errors
        assert not errors
        assert reference.outputs["indicator"] == "UNKNOWN"  # Non-actuating reference dry run.
        before = engine.counters["invalid_messages"]
        with lock:
            packet = reference.status(time.time())
        # Retained subscription delivery must never refresh the binding.
        receiver.publish(
            prefix + "/status", json.dumps(packet), qos=1, retain=True
        ).wait_for_publish(2)
        transport.client.unsubscribe(prefix + "/status")
        transport.client.subscribe(prefix + "/status", qos=1)
        deadline = time.monotonic() + 3
        while engine.counters["invalid_messages"] == before and time.monotonic() < deadline:
            now = time.monotonic()
            engine.step(
                {z: {"state": "UNKNOWN", "observed_at": None} for z in ZONE_IDS}, now, time.time()
            )
            time.sleep(0.02)
        assert engine.counters["invalid_messages"] > before
    finally:
        transport.close()
        receiver.disconnect()
        receiver.loop_stop()


def test_real_broker_shutdown_clears_transport_health_and_pending_state(broker, phase5_factory):
    port, child = broker
    cfg = local_config(phase5_factory, port)
    transport = MQTTTransport(cfg, "disconnect-session")
    transport.start()
    try:
        await_condition(lambda: transport.connected)
        child.terminate()
        child.wait(timeout=5)
        await_condition(lambda: not transport.connected)
        assert not transport.publish(cfg.data["mqtt"]["prefix"] + "/telemetry", {"test": True})
        assert transport.drain() == []
    finally:
        transport.close()
