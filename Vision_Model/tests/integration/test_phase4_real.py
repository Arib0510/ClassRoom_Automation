"""Genuine official checkpoint on real photographs; no injected detections or model mocks."""

import numpy as np
import pytest
from PIL import Image

from src.config import REPO_ROOT
from src.experimental_detector import YOLOv5n, person_candidates, person_nms, prediction_records

pytestmark = pytest.mark.real_inference


@pytest.mark.parametrize("size", [320, 416])
def test_genuine_cpu_inference_and_official_postprocess_equivalence(size):
    model = YOLOv5n(size)
    path = REPO_ROOT / "sample_images/IMG_20261013_133640_1.jpg"
    records, metadata = model.predict(path)
    assert model.invocations == 1
    assert model.person_id == 0 and model.names[0] == "person"
    assert next(model.model.parameters()).device.type == "cpu"
    assert metadata["input_size_wh"] == [size, size]
    assert len(records) > 0  # Actual recognition, independent from accuracy assertions.
    from utils.general import non_max_suppression

    reference = non_max_suppression(
        model.torch.from_numpy(model.last_raw.copy()),
        conf_thres=0.1,
        iou_thres=0.45,
        classes=[model.person_id],
    )[0].numpy()
    candidates = person_candidates(model.last_raw, 0.1, model.person_id)
    np.testing.assert_allclose(candidates[person_nms(candidates)], reference, atol=1e-5)
    reference_records = prediction_records(reference, path.name, model.model_id, metadata)
    np.testing.assert_allclose(
        [[r[k] for k in ("xmin", "ymin", "xmax", "ymax", "confidence")] for r in records],
        [[r[k] for k in ("xmin", "ymin", "xmax", "ymax", "confidence")] for r in reference_records],
        atol=1e-5,
    )


def test_all_saved_classroom_outputs_agree_with_official_nms():
    from pathlib import Path

    model = YOLOv5n(320)
    from utils.general import non_max_suppression

    paths = sorted(Path("outputs/phase4_model_comparison/raw").glob("*/*.npz"))
    assert len(paths) == 54
    for path in paths:
        raw = np.load(path, allow_pickle=False)["decoded"]
        reference = non_max_suppression(
            model.torch.from_numpy(raw.copy()), conf_thres=0.1, iou_thres=0.45, classes=[0]
        )[0].numpy()
        rows = person_candidates(raw, 0.1, model.person_id)
        np.testing.assert_allclose(rows[person_nms(rows)], reference, atol=1e-5)


def test_real_preprocessing_exif_and_rgb(tmp_path):
    model = YOLOv5n(320)
    image = Image.new("RGB", (40, 20), (240, 20, 5))
    exif = image.getexif()
    exif[274] = 6
    path = tmp_path / "rotated.jpg"
    image.save(path, exif=exif)
    tensor, metadata = model.prepare(path)
    assert metadata["original_size_wh"] == [20, 40]
    assert metadata["encoded_size_wh"] == [40, 20]
    assert tensor.shape == (1, 3, 320, 320)
    assert tensor[0, 0, 160, 160] > tensor[0, 2, 160, 160]
    model.predict(path)  # Actual kernel execution on the oriented image.
    assert model.invocations == 1
