import csv
import json
from pathlib import Path

import pytest
from PIL import Image

from src import image_inference
from src.config import load_config
from src.detector import Detection, ModelContractError
from src.inference_runtime import create_interpreter
from src.main import main


class UnitTestDetector:
    """Explicit fixture for report tests only; never a CLI/backend implementation."""

    runtime_info = {"backend": "UNIT_TEST_FIXTURE", "version": "test"}
    input_width = input_height = 300

    def __init__(self):
        self.invocation_count = 0

    def allocated_metadata(self):
        return {"allocated": True, "invocation_count": self.invocation_count}

    def detect(self, rgb):
        self.invocation_count += 1
        if self.invocation_count == 2:
            return []
        return [Detection((0.1, 0.2, 0.8, 0.7), 0.9, 0)]


@pytest.fixture
def inputs(tmp_path):
    folder = tmp_path / "input"
    folder.mkdir()
    for name in ("a.jpg", "b.png"):
        Image.new("RGB", (100, 50), "white").save(folder / name)
    return folder


def test_csv_json_annotations_and_zero_detection_images_are_reported(tmp_path, inputs, monkeypatch):
    fixture = UnitTestDetector()
    monkeypatch.setattr(image_inference, "create_detector", lambda *a, **kw: fixture)
    output = tmp_path / "output"
    summary = image_inference.infer_images(load_config(), inputs, output, overlay_zones=True)
    assert summary["images_discovered"] == summary["images_processed"] == 2
    assert summary["images_with_person_detections"] == summary["total_person_detections"] == 1
    assert not summary["accuracy_evaluated"]
    with (output / "detections.csv").open(newline="") as handle:
        rows = list(csv.DictReader(handle))
    assert len(rows) == 1 and rows[0]["image_filename"] == "a.jpg"
    assert float(rows[0]["xmin"]) == 20 and float(rows[0]["xmin_normalized"]) == 0.2
    predictions = json.loads((output / "detections.json").read_text())
    assert predictions["result_type"] == "model_predictions"
    assert predictions["images"][1]["detections"] == []
    assert all((output / record["annotated_image"]).is_file() for record in predictions["images"])
    metadata = json.loads((output / "inference_metadata.json").read_text())
    assert (
        metadata["status"] == "completed" and metadata["allocated_tensors"]["invocation_count"] == 2
    )
    assert metadata["zone_overlay"] == {"enabled": True, "label": "UNCALIBRATED"}
    assert metadata["mqtt_used"] is False and metadata["camera_used"] is False
    assert metadata["model"]["sha256"] == load_config().detector.sha256


def test_unreadable_image_is_not_a_zero_detection_success(tmp_path, inputs, monkeypatch):
    monkeypatch.setattr(image_inference, "create_detector", lambda *a, **kw: UnitTestDetector())
    (inputs / "corrupt.jpeg").write_bytes(b"broken")
    output = tmp_path / "output"
    summary = image_inference.infer_images(load_config(), inputs, output)
    assert summary["status"] == "completed_with_errors"
    assert summary["images_processed"] == 2 and summary["images_failed"] == 1
    records = json.loads((output / "detections.json").read_text())["images"]
    assert records[-1]["status"] == "unreadable" and records[-1]["error"]


def test_allocation_failure_is_recorded_and_stops_without_inference(tmp_path, inputs, monkeypatch):
    def fail(*args, **kwargs):
        raise RuntimeError("exact native allocation error")

    monkeypatch.setattr(image_inference, "create_detector", fail)
    output = tmp_path / "output"
    with pytest.raises(RuntimeError, match="exact native allocation error"):
        image_inference.infer_images(load_config(), inputs, output)
    metadata = json.loads((output / "inference_metadata.json").read_text())
    assert metadata["status"] == "failed"
    assert metadata["error"]["message"] == "exact native allocation error"
    assert metadata["processing"]["images_processed"] == 0
    assert not list((output / "annotated").iterdir())


def test_bad_model_output_stops_batch_and_preserves_failure(tmp_path, inputs, monkeypatch):
    fixture = UnitTestDetector()

    def fail(rgb):
        raise ModelContractError("invalid actual output")

    monkeypatch.setattr(fixture, "detect", fail)
    monkeypatch.setattr(image_inference, "create_detector", lambda *a, **kw: fixture)
    output = tmp_path / "output"
    with pytest.raises(RuntimeError, match="invalid actual output"):
        image_inference.infer_images(load_config(), inputs, output)
    summary = json.loads((output / "summary.json").read_text())
    assert summary["status"] == "failed" and summary["images_processed"] == 0
    assert summary["images_failed"] == 1 and summary["images_not_attempted"] == 1


def test_existing_results_are_preserved(tmp_path, inputs, monkeypatch):
    output = tmp_path / "output"
    output.mkdir()
    marker = output / "do-not-replace.json"
    marker.write_text("existing")
    with pytest.raises(ValueError, match="existing results preserved"):
        image_inference.infer_images(load_config(), inputs, output)
    assert marker.read_text() == "existing"


@pytest.mark.parametrize(
    "arguments",
    [
        ["infer-images"],
        ["infer-images", "--input", "sample_images"],
        ["infer-images", "--output", "outputs/test"],
        ["check-config", "--input", "sample_images"],
        ["run", "--runtime", "tensorflow"],
        [
            "infer-images",
            "--input",
            "sample_images",
            "--output",
            "outputs/test",
            "--runtime",
            "fake",
        ],
    ],
)
def test_cli_argument_validation(arguments):
    with pytest.raises(SystemExit) as exc:
        main(arguments)
    assert exc.value.code == 2


def test_cli_offline_mode_avoids_mqtt_and_reports_partial_failure(
    tmp_path, inputs, monkeypatch, capsys
):
    from src.mqtt_client import MQTTPublisher

    def no_mqtt(*args, **kwargs):
        raise AssertionError("Offline inference must not create a publisher")

    monkeypatch.setattr(MQTTPublisher, "__init__", no_mqtt)
    monkeypatch.setattr(image_inference, "create_detector", lambda *a, **kw: UnitTestDetector())
    (inputs / "corrupt.png").write_bytes(b"invalid")
    code = main(["infer-images", "--input", str(inputs), "--output", str(tmp_path / "output")])
    assert code == 2
    assert json.loads(capsys.readouterr().out)["images_failed"] == 1


def test_unsupported_runtime_is_rejected_without_fallback():
    with pytest.raises(ValueError, match="Unsupported inference backend"):
        create_interpreter(Path("unused.tflite"), 2, "invented")
