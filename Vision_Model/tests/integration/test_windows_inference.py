"""Actual model kernels on native Windows; opt in with --run-real-inference.

No monkeypatches, injected interpreters or fabricated model output are used here.
"""

import json
import sys

import numpy as np
import pytest
from PIL import Image

from src.config import load_config
from src.detector import create_detector
from src.main import main

pytestmark = pytest.mark.real_inference


def test_actual_windows_model_allocation_and_invocation():
    assert sys.platform == "win32", "This integration suite targets native Windows"
    detector = create_detector(load_config().detector, backend="tensorflow")
    metadata = detector.allocated_metadata()
    assert metadata["inputs"][0]["shape"] == [1, 300, 300, 3]
    assert metadata["inputs"][0]["dtype"] == "uint8"
    assert metadata["ssd_postprocess_supported"]
    assert metadata["outputs"][1]["shape"] == [1, 20, 4]  # Observed on the real allocation.
    detector.detect(np.zeros((480, 640, 3), dtype=np.uint8))
    assert detector.invocation_count == 1
    assert "tensorflow" in detector.runtime_info["interpreter_class"]
    for detail in detector.interpreter.get_output_details():
        output = detector.interpreter.get_tensor(detail["index"])
        assert np.all(np.isfinite(output))


def test_actual_cli_infers_and_writes_prediction_artifacts(tmp_path, capsys):
    folder = tmp_path / "input"
    folder.mkdir()
    # Real neural inference on a generated input. No assertion of recognition accuracy.
    Image.new("RGB", (80, 60), "gray").save(folder / "input.jpg")
    output = tmp_path / "output"
    assert (
        main(
            [
                "infer-images",
                "--input",
                str(folder),
                "--output",
                str(output),
                "--runtime",
                "tensorflow",
            ]
        )
        == 0
    )
    summary = json.loads(capsys.readouterr().out)
    assert summary["images_processed"] == 1
    metadata = json.loads((output / "inference_metadata.json").read_text())
    assert metadata["runtime"]["backend"] == "tensorflow"
    assert metadata["allocated_tensors"]["invocation_count"] == 1
    assert len(list((output / "annotated").glob("*.jpg"))) == 1
