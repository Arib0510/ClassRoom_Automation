from dataclasses import replace

import numpy as np
import pytest
from test_detector_adapter import FakeInterpreter

from src.config import load_config
from src.crops import ROI, Crop, CropPrediction, box_iou, global_nms, infer_crops, make_crops
from src.detector import Detection, SSDAdapter
from src.phase3_diagnostics import prediction_row, select_predictions


@pytest.mark.parametrize(
    "values",
    [
        (-0.1, 0, 1, 1),
        (0, 0, 1.1, 1),
        (0, 0.5, 1, 0.5),
        (0.7, 0, 0.2, 1),
        (0, float("nan"), 1, 1),
        (0, 0, 1, float("inf")),
        (False, 0, 1, 1),
        ("0", 0, 1, 1),
    ],
)
def test_invalid_roi_rejected(values):
    with pytest.raises(ValueError, match="ROI"):
        ROI(*values)


@pytest.mark.parametrize("overlap", [-0.1, 0.9, 1, float("nan"), True])
def test_invalid_overlap_rejected(overlap):
    with pytest.raises(ValueError, match="Overlap"):
        make_crops((640, 480), "overlap", overlap=overlap)


@pytest.mark.parametrize("mode,count", [("full", 1), ("roi", 1), ("left_right", 2), ("overlap", 4)])
def test_modes_cover_the_intended_roi_without_gaps(mode, count):
    size = (101, 79)  # Odd dimensions exercise crop rounding.
    roi = ROI(0.1, 0.35, 0.95, 0.99)
    crops = make_crops(size, mode, roi)
    assert len(crops) == count
    coverage = np.zeros((size[1], size[0]), dtype=int)
    for crop in crops:
        x0, y0, x1, y1 = crop.pixels
        coverage[y0:y1, x0:x1] += 1
    target = make_crops(size, "full" if mode == "full" else "roi", roi)[0].pixels
    x0, y0, x1, y1 = target
    assert coverage[y0:y1, x0:x1].min() >= 1
    assert np.count_nonzero(coverage) == (x1 - x0) * (y1 - y0)
    if mode == "overlap":
        assert coverage.max() == 4


def test_transforms_use_actual_integer_crop_bounds_not_requested_fraction():
    crop = make_crops((101, 79), "roi", ROI(0.1, 0.35, 0.95, 0.99))[0]
    assert crop.pixels == (10, 27, 96, 79)
    detection = Detection((0.25, 0.125, 0.75, 0.875), 0.5703125, 0)
    result = crop.reproject(detection)
    assert result.box == pytest.approx(
        ((27 + 13) / 79, (10 + 10.75) / 101, (27 + 39) / 79, (10 + 75.25) / 101)
    )
    assert result.score == detection.score
    assert result.class_id == 0
    whole = crop.reproject(Detection((0, 0, 1, 1), 0.1, 0))
    assert whole.box == pytest.approx((27 / 79, 10 / 101, 1, 96 / 101))


@pytest.mark.parametrize("pixels", [(0, 0, 0, 5), (-1, 0, 5, 5), (0, 0, 11, 10), (0.0, 0, 10, 10)])
def test_invalid_pixel_crop_rejected(pixels):
    with pytest.raises(ValueError, match="Crop"):
        Crop("bad", pixels, (10, 10))


def test_duplicate_merge_preserves_winner_and_does_not_merge_distinct_people():
    crop = Crop("left", (0, 0, 100, 100), (100, 100))
    second = Crop("right", (0, 0, 100, 100), (100, 100))
    box = (0.1, 0.1, 0.4, 0.4)
    predictions = [
        CropPrediction(Detection(box, 0.2, 0), crop, box),
        CropPrediction(Detection(box, 0.7, 0), second, box),
        CropPrediction(Detection((0.6, 0.6, 0.9, 0.9), 0.6, 0), crop, box),
        CropPrediction(Detection(box, 0.5, 2), crop, box),
    ]
    assert global_nms(predictions) == [1, 2, 3]
    row = prediction_row(predictions[1], "test.jpg", 2)
    assert row["confidence"] == 0.7
    assert row["source_crop"] == "right"
    assert row["xmin"] == 10
    kept, suppressed = select_predictions(
        [prediction_row(p, "test.jpg", i + 1) for i, p in enumerate(predictions[:3])],
        "left_right",
        0.1,
        0.5,
    )
    assert [r["detection_index"] for r in kept] == [2, 3]
    assert suppressed == [1]


def test_iou_and_score_ties_are_deterministic():
    a, b = (0, 0, 1, 1), (0, 0, 1, 0.5)
    assert box_iou(a, b) == 0.5
    crop = Crop("test", (0, 0, 1, 1), (1, 1))
    predictions = [CropPrediction(Detection(box, 0.4, 0), crop, box) for box in (a, b)]
    assert global_nms(predictions, 0.5) == [0]
    assert global_nms(predictions, 0.51) == [0, 1]


def test_crops_reuse_adapter_and_diagnostic_override_preserves_production_threshold():
    config = load_config().detector
    fake = FakeInterpreter(config)
    adapter = SSDAdapter(config, fake)
    rgb = np.zeros((81, 101, 3), dtype=np.uint8)
    predictions = infer_crops(adapter, rgb, make_crops((101, 81), "left_right"))
    assert fake.invocations == 2
    assert adapter.invocation_count == 2
    assert fake.submitted.shape == (1, 300, 300, 3)
    assert len(predictions) == 4  # Two actual synthetic person slots per crop, including 0.1.
    assert predictions[-1].detection.box == pytest.approx((0, 50 / 101, 1, 1))
    assert adapter.config.confidence_threshold == 0.55
    assert len(adapter.detect(rgb)) == 1
    all_scores = adapter.detect(rgb, confidence_threshold=0)
    assert [p.score for p in all_scores] == pytest.approx([0.9, 0.1])
    with pytest.raises(ValueError):
        adapter.detect(rgb, confidence_threshold=float("nan"))
    assert fake.invocations == 4  # Invalid threshold must fail before invoke.


def test_native_input_size_enforced_for_classroom_experiment():
    config = replace(load_config().detector, input_width=2, input_height=2)
    adapter = SSDAdapter(config, FakeInterpreter(config))
    with pytest.raises(ValueError, match="300x300"):
        infer_crops(adapter, np.zeros((10, 10, 3), dtype=np.uint8), make_crops((10, 10)))
