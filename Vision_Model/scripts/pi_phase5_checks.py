"""Explicit teammate operations; software artifacts never count as target acceptance."""

from __future__ import annotations

import argparse
import importlib.metadata
import json
import os
import platform
import shutil
import struct
import sys
import threading
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from src.phase5_acceptance import external_trials, templates  # noqa: E402
from src.phase5_config import load_phase5  # noqa: E402
from src.phase5_metrics import statistics  # noqa: E402


def environment():
    versions = {}
    for package in ("numpy", "Pillow", "PyYAML", "paho-mqtt", "tflite-runtime"):
        try:
            versions[package] = importlib.metadata.version(package)
        except importlib.metadata.PackageNotFoundError:
            versions[package] = None
    os_release = Path("/etc/os-release")
    cpu = Path("/proc/cpuinfo")
    memory = Path("/proc/meminfo")
    release = os_release.read_text() if os_release.exists() else ""
    result = {
        "platform": platform.platform(),
        "machine": platform.machine(),
        "bits": struct.calcsize("P") * 8,
        "python": platform.python_version(),
        "os_release": release,
        "cpuinfo": cpu.read_text() if cpu.exists() else None,
        "meminfo": memory.read_text() if memory.exists() else None,
        "storage_free_bytes": shutil.disk_usage(ROOT).free,
        "packages": versions,
        "target_matches": platform.system() == "Linux"
        and struct.calcsize("P") == 4
        and platform.machine() in ("armv7l", "armv8l")
        and sys.version_info[:2] == (3, 11)
        and "VERSION_CODENAME=bookworm" in release,
        "hardware_acceptance": "PENDING",
    }
    return result


def mqtt_probe(config, timeout=10):
    from paho.mqtt import client as mqtt

    if not config.data["mqtt"]["enabled"]:
        raise ValueError("Enable broker explicitly in a dedicated test configuration")
    token = uuid.uuid4().hex
    topic = config.data["mqtt"]["prefix"] + "/diagnostics/probe/" + token
    arrived, connected = threading.Event(), threading.Event()
    times = {}
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="phase5-probe-" + token)

    def on_connect(client, userdata, flags, reason_code, properties):
        if reason_code == 0:
            client.subscribe(topic, qos=1)

    def on_subscribe(client, userdata, mid, reason_codes, properties):
        connected.set()

    def on_message(client, userdata, message):
        if message.topic == topic and message.payload == token.encode() and not message.retain:
            times["received"] = time.monotonic()
            arrived.set()

    client.on_connect, client.on_subscribe, client.on_message = on_connect, on_subscribe, on_message
    broker = config.base.mqtt
    if os.getenv(broker.username_env):
        client.username_pw_set(os.getenv(broker.username_env), os.getenv(broker.password_env))
    if broker.tls:
        client.tls_set(ca_certs=str(broker.ca_path) if broker.ca_path else None)
    client.connect_async(broker.host, broker.port, broker.keepalive)
    client.loop_start()
    try:
        if not connected.wait(timeout):
            raise TimeoutError("Broker connect/subscribe timed out")
        times["sent"] = time.monotonic()
        client.publish(topic, token, qos=1, retain=False)
        if not arrived.wait(timeout):
            raise TimeoutError("Broker echo timed out")
        return {
            "broker_roundtrip_seconds": times["received"] - times["sent"],
            "topic": topic,
            "broker_tested": True,
            "esp32_tested": False,
            "physical_output_tested": False,
        }
    finally:
        client.disconnect()
        client.loop_stop()


def inference_benchmark(config, image_path, output, count, strategy, timeout):
    import yaml

    from src.images import load_rgb_image
    from src.phase5_workers import BoundedWorker

    if not 1 <= count <= 1000 or not 0.1 <= timeout <= 120:
        raise ValueError("Bounded count 1..1000 and timeout .1..120 required")
    output.mkdir(parents=True, exist_ok=False)
    settings = dict(config.data)
    settings["base_config"] = str(config.path.parent / settings["base_config"])
    settings["strategy"] = dict(
        settings["strategy"], mode=strategy, allow_multipass=strategy in ("left_right", "overlap")
    )
    settings["mode"], settings["mqtt"] = "OBSERVE", dict(settings["mqtt"], enabled=False)
    settings["commissioning"] = settings["authorization"] = None
    path = output / "benchmark_config.yaml"
    path.write_text(yaml.safe_dump(settings))
    worker = BoundedWorker("detector", path)
    records = []
    try:
        worker.wait_ready(config.data["resources"]["startup_timeout_seconds"])
        image = load_rgb_image(image_path)
        for index in range(count):
            frame = {
                "rgb": image.rgb,
                "frame_id": f"benchmark-{index}",
                "captured_at": time.monotonic(),
            }
            result = worker.call(frame, timeout)
            records.append(
                {
                    "phase": "cold_start" if index == 0 else "sustained",
                    "timings": result["timings"],
                    "passes": result["passes"],
                    "detections": result["records"],
                    "total_detector_seconds": result["total_detector_seconds"],
                }
            )
    finally:
        worker.close()
        result = {
            "source": "pi_saved_image"
            if environment()["target_matches"]
            else "desktop_saved_image",
            "camera_tested": False,
            "physical_output_tested": False,
            "strategy": strategy,
            "records": records,
            "statistics_by_phase": {
                phase: statistics(
                    [r["total_detector_seconds"] for r in records if r["phase"] == phase]
                )
                for phase in ("cold_start", "sustained")
            },
        }
        (output / "benchmark.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=(
            "environment",
            "camera-list",
            "mqtt-probe",
            "infer",
            "templates",
            "external-summary",
        ),
    )
    parser.add_argument("--config", type=Path, default=ROOT / "config/phase5.example.yaml")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--input", type=Path)
    parser.add_argument("--count", type=int, default=10)
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument(
        "--strategy", choices=("single_pass", "left_right", "overlap", "roi"), default="single_pass"
    )
    args = parser.parse_args(argv)
    if args.output.exists():
        raise ValueError("Choose a new output file/directory")
    if args.command == "templates":
        templates(args.output)
        return 0
    config = load_phase5(args.config)
    if args.command == "environment":
        result = environment()
    elif args.command == "camera-list":
        if not environment()["target_matches"]:
            raise ValueError("Camera enumeration is target-only")
        from picamera2 import Picamera2

        result = {"cameras": Picamera2.global_camera_info(), "capture_tested": False}
    elif args.command == "mqtt-probe":
        result = mqtt_probe(config)
    elif args.command == "infer":
        if args.input is None:
            raise ValueError("infer requires --input saved image")
        inference_benchmark(
            config, args.input, args.output, args.count, args.strategy, args.timeout
        )
        return 0
    else:
        result = external_trials(args.input)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
