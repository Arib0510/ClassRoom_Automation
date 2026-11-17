from __future__ import annotations

import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace

import pytest

SCRIPT = Path(__file__).parents[1] / "scripts/run_classroom_vision.py"
SPEC = importlib.util.spec_from_file_location("run_classroom_vision", SCRIPT)
runtime = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runtime)


class FakeMQTT:
    def __init__(self):
        self.published = []

    def publish(self, *args, **kwargs):
        self.published.append((args, kwargs))


def test_dry_run_only_routes_simulation_and_refuses_physical_topic(monkeypatch):
    controller = runtime.ClassroomVisionController.__new__(runtime.ClassroomVisionController)
    controller.dry_run_only = True
    controller.mode = "DRY_RUN"
    controller.room_id = "reb_room_301"
    controller.command_seq = 1
    controller.session_id = "unit-test"
    controller.mqtt_client = FakeMQTT()
    monkeypatch.setattr(runtime, "mqtt", object())

    controller._send_esp32_command("board01", 1, "ON")
    topic, payload = controller.mqtt_client.published[-1][0][:2]
    assert topic == "classpulse/reb_room_301/controllers/board01/dry_run/command"
    assert json.loads(payload)["mode"] == "DRY_RUN"
    assert "/dry_run/command" in topic
    assert topic != "classpulse/reb_room_301/controllers/board01/command"

    controller.mode = "LIVE"
    controller._send_esp32_command("board01", 1, "ON")
    assert len(controller.mqtt_client.published) == 1


def test_dry_run_lock_rejects_preview_http_live_switch():
    class Writer:
        def write(self, value):
            self.value = value

    class Controller:
        dry_run_only = True
        mode = "DRY_RUN"

    class Server:
        controller = Controller()
        preview_state = runtime.PreviewState()

    class Handler:
        path = "/api/config?mode=LIVE"
        server = Server()
        wfile = Writer()

        def send_response(self, code):
            self.code = code

        def send_header(self, *args):
            pass

        def end_headers(self):
            pass

    handler = Handler()
    runtime.PreviewHTTPHandler.do_GET(handler)
    assert handler.code == 403
    assert handler.server.controller.mode == "DRY_RUN"


def test_mqtt_uses_credentials_and_bounded_async_reconnect(monkeypatch):
    class Client:
        def __init__(self):
            self.calls = []

        def __getattr__(self, name):
            def record(*args, **kwargs):
                self.calls.append((name, args, kwargs))

            return record

    fake = Client()
    monkeypatch.setenv("CLASSROOM_MQTT_USERNAME", "pi-vision")
    monkeypatch.setenv("CLASSROOM_MQTT_PASSWORD", "test-only")
    monkeypatch.setattr(
        runtime,
        "mqtt",
        SimpleNamespace(CallbackAPIVersion=SimpleNamespace(VERSION1=1), Client=lambda *a, **k: fake),
    )
    controller = runtime.ClassroomVisionController.__new__(runtime.ClassroomVisionController)
    controller.room_id = "reb_room_301"
    controller.broker = "10.247.68.155"
    controller.port = 1883
    controller.session_id = "unit-test"
    controller.front_board_id = "board01"
    controller.back_board_id = "board02"
    controller.third_board_id = "board03"
    controller.setup_mqtt()
    calls = {name: (args, kwargs) for name, args, kwargs in fake.calls}
    assert calls["reconnect_delay_set"] == ((), {"min_delay": 1, "max_delay": 10})
    assert calls["username_pw_set"][0] == ("pi-vision", "test-only")
    assert calls["connect_async"][0] == ("10.247.68.155", 1883)
    assert "connect" not in calls
    assert "loop_start" in calls


def test_camera_startup_failure_releases_preview_and_mqtt():
    controller = runtime.ClassroomVisionController.__new__(runtime.ClassroomVisionController)

    class Resource:
        def __init__(self):
            self.closed = []

        def shutdown(self):
            self.closed.append("shutdown")

        def server_close(self):
            self.closed.append("server_close")

        def is_connected(self):
            return False

        def disconnect(self):
            self.closed.append("disconnect")

        def loop_stop(self):
            self.closed.append("loop_stop")

    preview, mqtt_client = Resource(), Resource()
    controller.preview_server = preview
    controller.mqtt_client = mqtt_client
    controller._cleanup_startup_failure()
    assert preview.closed == ["shutdown", "server_close"]
    assert mqtt_client.closed == ["disconnect", "loop_stop"]
    assert controller.preview_server is None


def test_deployment_manifest_keeps_model_and_six_zone_defaults_unchanged():
    root = SCRIPT.parents[1]
    model = root / "models/classroom_yolo_best.pt"
    assert model.is_file()
    zones = json.loads((root / "config/six_zone_runtime.json").read_text())
    assert zones["zone_ids"] == list(runtime.SIX_ZONE_IDS)
    assert zones["split_y"] == 0.48
    assert zones["column_boundaries_x"] == [0.34, 0.66]
    assert zones["invert_zones"] is True


def test_pi_package_builder_excludes_secrets_and_verifies_model_hash(tmp_path):
    builder_path = SCRIPT.parents[1] / "scripts/build_pi5_deployment.py"
    builder_spec = importlib.util.spec_from_file_location("build_pi5_deployment", builder_path)
    builder = importlib.util.module_from_spec(builder_spec)
    builder_spec.loader.exec_module(builder)
    archive = builder.build(tmp_path / "Classroom_Vision_Pi5_Deployment.zip")
    manifest = builder.verify(archive)
    assert "models/classroom_yolo_best.pt" in manifest["files"]
    with __import__("zipfile").ZipFile(archive) as zipped:
        names = zipped.namelist()
    assert not any(name.endswith("/config/mqtt.env") for name in names)
    assert any(name.endswith("/config/mqtt.env.example") for name in names)
    assert any(name.endswith("/scripts/smoke_test_pi5_inference.py") for name in names)
    assert any(name.endswith("/requirements-pi5-support.txt") for name in names)


def test_trixie_requirements_pin_python313_arm_pair_without_pip_opencv():
    root = SCRIPT.parents[1]
    core = (root / "requirements-pi5.txt").read_text()
    support = (root / "requirements-pi5-support.txt").read_text().lower()
    assert "torch==2.8.0" in core
    assert "torchvision==0.23.0" in core
    assert "ultralytics==8.3.223" in core
    assert "numpy<2" not in core.lower()
    assert "opencv-python" not in core.lower()
    assert "opencv-python" not in support
