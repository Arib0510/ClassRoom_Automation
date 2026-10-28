"""Execute exported native kernels, including NCNN with owned input memory."""

import json
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

from src.experimental_detector import person_candidates, person_nms
from src.person_labels import source_hash

pytestmark = pytest.mark.real_inference
EXPORTS = Path("outputs/phase4_model_comparison/exports")


@pytest.mark.parametrize("size", [320, 416])
def test_real_onnx_and_ncnn_kernels_match_pytorch_evidence(size, tmp_path):
    import onnxruntime as ort

    report = json.loads((EXPORTS / "export_verification.json").read_text())
    record = next(e for e in report["exports"] if e["size"] == size)
    assert record["equivalent_on_samples"]
    for artifact in record["artifacts"]:
        assert source_hash(EXPORTS / artifact["file"]) == artifact["sha256"]
    sample = "IMG_20261013_133640_1.jpg"
    prepared = EXPORTS / f"input_{size}_{sample}.npy"
    saved = np.load(EXPORTS / f"equivalence_{size}_{sample}.npz", allow_pickle=False)
    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    session = ort.InferenceSession(
        str(EXPORTS / f"yolov5n_{size}.onnx"), options, providers=["CPUExecutionProvider"]
    )
    actual = session.run(None, {session.get_inputs()[0].name: np.load(prepared)})[0]
    np.testing.assert_allclose(actual, saved["pytorch"], rtol=1e-4, atol=1e-3)
    output = tmp_path / "actual.npy"
    subprocess.run(
        [
            sys.executable,
            "scripts/infer_phase4_ncnn.py",
            "--param",
            str(EXPORTS / f"yolov5n_{size}.ncnn.param"),
            "--bin",
            str(EXPORTS / f"yolov5n_{size}.ncnn.bin"),
            "--input",
            str(prepared),
            "--output",
            str(output),
        ],
        check=True,
        timeout=120,
    )
    actual = np.load(output)
    np.testing.assert_allclose(actual, saved["pytorch"], rtol=1e-4, atol=1e-3)
    observed = person_candidates(actual, 0.1, 0)
    expected = person_candidates(saved["pytorch"], 0.1, 0)
    np.testing.assert_allclose(
        observed[person_nms(observed)], expected[person_nms(expected)], rtol=1e-4, atol=1e-3
    )
