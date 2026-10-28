"""Synthetic camera/transport, bounded worker, replay, log and packaging contracts."""

import csv
import importlib.util
import json
import time
import zipfile
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest
import test_phase5_control

from src.phase5_acceptance import external_trials, templates
from src.phase5_capture import CaptureSource, ImageSource
from src.phase5_config import digest, load_phase5
from src.phase5_data import DatasetWriter, export_dataset
from src.phase5_metrics import EventLog, statistics, summarize
from src.phase5_mqtt import MQTTTransport
from src.phase5_runtime import main, replay, run_service
from src.phase5_workers import BoundedWorker
from src.zones import ZONE_IDS

phase5_factory = test_phase5_control.phase5_factory


class Request:
    def __init__(self, rgb, sensor):
        self.rgb, self.sensor = rgb, sensor
        self.released = False

    def make_array(self, name):
        return self.rgb

    def get_metadata(self):
        return {"SensorTimestamp": self.sensor}

    def release(self):
        self.released = True


class Camera:
    def __init__(self, request):
        self.request = request
        self.closed = self.stopped = False

    def capture_request(self, wait):
        return SimpleNamespace(get_result=lambda timeout: self.request)

    def stop(self):
        self.stopped = True

    def close(self):
        self.closed = True


@pytest.mark.parametrize(
    "rotation,shape",
    [(0, (480, 640, 3)), (90, (640, 480, 3)), (180, (480, 640, 3)), (270, (640, 480, 3))],
)
def test_camera_orientation_timestamps_rgb_and_cleanup(phase5_factory, rotation, shape):
    cfg = phase5_factory()
    cfg.data["camera"]["rotation"] = rotation
    rgb = np.zeros((480, 640, 3), dtype=np.uint8)
    rgb[..., 0] = 240
    request = Request(rgb, 1_950_000_000)
    camera = Camera(request)
    clock = iter([5, 5.1])
    source = CaptureSource(cfg, camera, clock=lambda: next(clock), boot_clock=lambda: 2)
    frame = source.capture()
    assert frame["rgb"].shape == shape
    assert frame["rgb"][0, 0, 0] == 240 and frame["rgb"][0, 0, 2] == 0
    assert frame["captured_at"] == pytest.approx(5)
    assert frame["capture_duration_seconds"] == pytest.approx(0.1)
    assert request.released
    source.close()
    assert camera.stopped and camera.closed


@pytest.mark.parametrize("sensor", [None, 0, 2_100_000_000, -1, "bad"])
def test_camera_missing_or_bad_sensor_clock_is_not_vacancy(phase5_factory, sensor):
    cfg = phase5_factory()
    request = Request(np.zeros((480, 640, 3), dtype=np.uint8), sensor)
    source = CaptureSource(cfg, Camera(request), clock=lambda: 5, boot_clock=lambda: 2)
    with pytest.raises(RuntimeError):
        source.capture()
    assert request.released


def test_camera_repeated_frame_and_timeout(phase5_factory):
    cfg = phase5_factory()
    request = Request(np.zeros((480, 640, 3), dtype=np.uint8), 1_950_000_000)
    source = CaptureSource(cfg, Camera(request), clock=lambda: 5, boot_clock=lambda: 2)
    source.capture()
    with pytest.raises(RuntimeError, match="Repeated"):
        source.capture()

    class TimeoutCamera(Camera):
        def capture_request(self, wait):
            def get_result(timeout):
                raise TimeoutError("capture stall")

            return SimpleNamespace(get_result=get_result)

    source = CaptureSource(cfg, TimeoutCamera(request))
    with pytest.raises(TimeoutError):
        source.capture()


def hung_worker(connection, kind, path, backend):
    connection.send(("ready", {}))
    connection.recv()
    time.sleep(30)


def unread_worker(connection, kind, path, backend):
    connection.send(("ready", {}))
    time.sleep(30)  # Deliberately never reads the parent's large pipe write.


def test_native_worker_timeout_services_ticks_and_does_not_leave_backlog(monkeypatch):
    import src.phase5_workers as module

    monkeypatch.setattr(module, "worker_main", hung_worker)
    worker = BoundedWorker("detector", "unused")
    ticks = []
    try:
        worker.wait_ready(10)
        start = time.monotonic()
        with pytest.raises(TimeoutError):
            worker.call(np.zeros((100, 100)), 0.15, lambda: ticks.append(1))
        assert ticks and time.monotonic() - start < 4
        assert not worker.process.is_alive()
    finally:
        worker.close()


def test_worker_startup_error_does_not_start_hardware(tmp_path):
    worker = BoundedWorker("detector", tmp_path / "missing.yaml")
    try:
        with pytest.raises(RuntimeError):
            worker.wait_ready(10)
    finally:
        worker.close()


def test_interrupt_during_blocked_ipc_send_is_bounded(monkeypatch):
    import src.phase5_workers as module

    monkeypatch.setattr(module, "worker_main", unread_worker)
    worker = BoundedWorker("detector", "unused")

    def interrupt():
        raise KeyboardInterrupt

    try:
        worker.wait_ready(10)
        started = time.monotonic()
        with pytest.raises(KeyboardInterrupt):
            worker.call(np.zeros((1000, 1000, 3), dtype=np.uint8), 10, interrupt)
        assert time.monotonic() - started < 4
        assert not worker.process.is_alive()
    finally:
        worker.close()


class Info:
    rc = 0

    def is_published(self):
        return True

    def wait_for_publish(self, timeout):
        pass


class MQTTClient:
    def __init__(self):
        self.calls = []

    def __getattr__(self, name):
        def method(*args, **kwargs):
            self.calls.append((name, args, kwargs))
            return Info()

        return method


def test_mqtt_transport_bounds_subscriptions_retain_and_shutdown(phase5_factory):
    cfg = phase5_factory()
    cfg.data["mqtt"]["enabled"] = True
    client = MQTTClient()
    transport = MQTTTransport(cfg, "test", client=client)
    assert not transport.publish("test-only/phase5/telemetry", {})
    transport.start()
    transport._connect(client, None, None, 0, None)
    assert transport.connected
    with pytest.raises((ValueError, KeyError)):
        transport.publish("test-only/phase5/controllers/board_a/dry_run/command", {"test": True})
    assert transport.publish("test-only/phase5/telemetry", {"test": True})
    assert client.calls[-1][2]["retain"] is False
    subscriptions = [args[0] for name, args, kwargs in client.calls if name == "subscribe"]
    assert subscriptions == [
        "test-only/phase5/controllers/board_a/status",
        "test-only/phase5/controllers/board_a/ack",
    ]
    for _ in range(130):
        transport._message(
            client, None, SimpleNamespace(topic="topic", payload=b"{}", retain=False)
        )
    assert len(transport.drain()) == 128 and transport.dropped_received == 2
    transport._disconnect(client, None, None, 1, None)
    assert not transport.connected
    assert not transport.publish("test-only/phase5/telemetry", {})
    transport.close()
    assert any(c[0] == "loop_stop" for c in client.calls)


def test_pipeline_replay_determinism_and_no_network(tmp_path, monkeypatch):
    import socket

    def forbidden(*args, **kwargs):
        raise AssertionError("No network during offline replay")

    monkeypatch.setattr(socket, "socket", forbidden)
    cfg = load_phase5()
    synthetic = tmp_path / "events.json"
    synthetic.write_text(
        json.dumps(
            {
                "source": "synthetic",
                "events": [
                    {"time": 0, "zones": dict.fromkeys(ZONE_IDS, "OCCUPIED")},
                    {"time": 0.5, "zones": dict.fromkeys(ZONE_IDS, "OCCUPIED")},
                    {"time": 1, "fault": "camera_disconnected"},
                ],
            }
        )
    )
    first = replay(cfg, synthetic, tmp_path / "one", synthetic=True)
    second = replay(cfg, synthetic, tmp_path / "two", synthetic=True)
    assert first == second
    assert first["results"][1]["zones"]["front_left"]["state"] == "OCCUPIED"
    assert first["results"][2]["zones"]["front_left"]["state"] == "UNKNOWN"
    assert first["mqtt_used"] is False
    with pytest.raises(FileExistsError):
        replay(cfg, synthetic, tmp_path / "one", synthetic=True)


def test_historical_photos_remain_unknown(tmp_path):
    result = replay(
        load_phase5(), Path("evaluation_baseline/ssd_run02_predictions.json"), tmp_path / "history"
    )
    assert len(result["results"]) == 27
    assert all(i["zones"][z]["state"] == "UNKNOWN" for i in result["results"] for z in ZONE_IDS)


def test_logging_rotates_and_statistics_do_not_mix_sources_or_imply_hardware(tmp_path):
    folder = tmp_path / "logs"
    log = EventLog(folder, {"max_bytes": 4096, "backup_count": 2}, "synthetic_replay")
    for i in range(80):
        log.write(
            "sample",
            phase="cold_start" if i == 0 else "sustained",
            timings={"inference_seconds": 0.1},
        )
    log.close()
    assert len(list(folder.iterdir())) <= 3
    summary = summarize(folder)
    assert summary["physical_arrival_to_activation"]["status"] == "PENDING"
    assert {g["provenance"] for g in summary["groups"]} == {"synthetic_replay"}
    result = statistics([1, 2, None, float("nan"), -1, True], 1.5)
    assert result["sample_count"] == 2 and result["invalid_or_incomplete"] == 4
    assert result["deadline_miss_count"] == 1 and result["p99"] is None
    assert statistics([1] * 100)["p99"] == 1


def test_lossless_collection_and_privacy_export_defaults(tmp_path):
    dataset = tmp_path / "dataset"
    writer = DatasetWriter(
        dataset, {"session_id": "synthetic-session", "consent_reference": "synthetic-test"}
    )
    rgb = np.arange(60, dtype=np.uint8).reshape(4, 5, 3)
    record = writer.save({"frame_id": "synthetic", "captured_at": 1, "rgb": rgb}, "synthetic")
    writer.close()
    assert record["physical_occupancy"] == dict.fromkeys(ZONE_IDS, "UNKNOWN")
    source = ImageSource([dataset / record["file_name"]])
    np.testing.assert_array_equal(source.capture()["rgb"], rgb)
    archive = tmp_path / "private.zip"
    export_dataset(dataset, archive)
    with zipfile.ZipFile(archive) as zipped:
        assert zipped.namelist() == ["manifest.json"]
    archive = tmp_path / "authorized-images.zip"
    export_dataset(dataset, archive, True)
    with zipfile.ZipFile(archive) as zipped:
        assert record["file_name"] in zipped.namelist()
    with pytest.raises(ValueError):
        export_dataset(dataset, archive, True)


def test_benchmark_template_cannot_pass_without_external_observation(tmp_path):
    templates(tmp_path / "acceptance")
    result = external_trials(tmp_path / "acceptance/external_trials.csv")
    assert result["status"] == "PENDING" and len(result["invalid_or_incomplete"]) == 4
    evidence = tmp_path / "synthetic-evidence.txt"
    evidence.write_text("synthetic same-instrument timestamps for parser test only")
    path = tmp_path / "trials.csv"
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=[
                "trial_id",
                "zone",
                "phase",
                "source",
                "clock_id",
                "arrival_seconds",
                "output_seconds",
                "evidence_file",
                "evidence_sha256",
            ],
        )
        writer.writeheader()
        writer.writerow(
            dict(
                trial_id="synthetic",
                zone="front_left",
                phase="sustained",
                source="external_synchronized_observation",
                clock_id="same-timeline",
                arrival_seconds=1,
                output_seconds=6.2,
                evidence_file=evidence.name,
                evidence_sha256=digest(evidence),
            )
        )
    result = external_trials(path)
    assert result["groups"][0]["deadline_miss_count"] == 1
    assert result["mains_authorized"] is False


def load_packager():
    spec = importlib.util.spec_from_file_location(
        "phase5_packager", "scripts/build_phase5_package.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_deployment_package_checksums_and_heavyweight_exclusions(tmp_path):
    builder = load_packager()
    archive = builder.create(tmp_path / "package")
    extracted = tmp_path / "extracted"
    with zipfile.ZipFile(archive) as zipped:
        names = zipped.namelist()
        assert not any(
            "yolo" in n.lower() or ".venv" in n or "requirements-windows" in n for n in names
        )
        assert "models/ssd_mobilenet_v2_coco_quant.tflite" in names
        zipped.extractall(extracted)
    manifest = builder.verify(extracted)
    assert manifest["appliances_authorized"] is False
    (extracted / "src/phase5_control.py").write_text("tampered")
    with pytest.raises(ValueError, match="checksum"):
        builder.verify(extracted)


def test_shutdown_on_failed_startup_cleans_transport(phase5_factory, tmp_path, monkeypatch):
    import src.phase5_workers as workers

    closed = []

    class FailureWorker:
        def __init__(self, *args):
            pass

        def wait_ready(self, *args):
            raise RuntimeError("synthetic startup failure")

        def close(self):
            closed.append(True)

    monkeypatch.setattr(workers, "BoundedWorker", FailureWorker)
    cfg = phase5_factory("OBSERVE")
    assert run_service(cfg, tmp_path / "failure-run", input_folder="sample_images") == 1
    assert closed
    records = [
        json.loads(line)
        for line in (tmp_path / "failure-run/events.jsonl").read_text().splitlines()
    ]
    assert records[-1]["event"] == "shutdown" and records[-1]["physical_outputs_confirmed"] is False


def test_live_camera_cli_refuses_windows_before_opening_hardware(tmp_path):
    import platform

    if platform.system() != "Windows":
        pytest.skip("Windows gate")
    with pytest.raises(SystemExit):
        main(["run", "--output", str(tmp_path / "unused")])
    assert not (tmp_path / "unused").exists()


def test_full_shared_pipeline_simulation_is_deterministic_and_never_uses_network(monkeypatch):
    import socket

    from src.phase5_simulation import SyntheticInterlock, simulate

    def forbidden(*args, **kwargs):
        raise AssertionError("Simulation tried a socket")

    monkeypatch.setattr(socket, "socket", forbidden)
    first, second = simulate(), simulate()
    assert first == second
    assert first["hardware_tested"] is False and first["gpio_used"] is False
    outputs = [o["simulated_outputs"]["synthetic_front_left"] for o in first["observations"]]
    assert "ON" in outputs and outputs[-1] == "OFF"
    assert first["counters"]["acknowledgements"] > 0
    assert any(e["event"] == "arrival_decision" for e in first["events"])
    with pytest.raises(ValueError):
        SyntheticInterlock(object())


@pytest.mark.parametrize("mode", ["LIVE_TEST", "LIVE_APPLIANCE"])
def test_live_run_requires_operator_before_network_or_camera(phase5_factory, tmp_path, mode):
    cfg = phase5_factory(mode)
    with pytest.raises(ValueError, match="operator"):
        run_service(cfg, tmp_path / "forbidden-start")
    assert not (tmp_path / "forbidden-start").exists()


def test_slow_mapping_cannot_authorize_stale_control(monkeypatch):
    import src.phase5_runtime as runtime
    from src.phase5_mqtt import MemoryTransport

    pipeline = runtime.Pipeline(load_phase5(), MemoryTransport(), "synthetic")
    times = iter([10, 15])
    monkeypatch.setattr(runtime.time, "monotonic", lambda: next(times))
    frame = {
        "frame_id": "slow",
        "captured_at": 10,
        "rgb": np.arange(600, dtype=np.uint8).reshape(10, 20, 3),
    }
    with pytest.raises(TimeoutError):
        pipeline.observe(frame, {"frame_id": "slow", "detections": []}, 10, 1_800_000_000)
    assert pipeline.temporal.snapshot(15)["front_left"]["state"] == "UNKNOWN"
