"""Actual classroom-image inference through all crop modes; no accuracy assertions."""

import pytest

from src.config import REPO_ROOT, load_config
from src.crops import MODES, ROI, infer_crops, make_crops
from src.detector import create_detector
from src.images import load_rgb_image

pytestmark = pytest.mark.real_inference


def test_actual_native_crops_reuse_allocation_and_preserve_full_image_baseline():
    detector = create_detector(load_config().detector, backend="tensorflow")
    loaded = load_rgb_image(REPO_ROOT / "sample_images/IMG_20261013_133640.jpg")
    baseline = detector.detect(loaded.rgb)
    assert (
        len(baseline) == 1
    )  # Previously recorded real baseline for these exact model/image bytes.
    for mode in MODES:
        crops = make_crops(loaded.image.size, mode, ROI(0, 0.35, 1, 1))
        outputs = infer_crops(detector, loaded.rgb, crops)
        if mode == "full":
            assert [p.detection for p in outputs if p.detection.score >= 0.55] == baseline
        for output in outputs:
            assert 0 <= output.detection.score <= 1
            assert all(0 <= v <= 1 for v in output.detection.box)
            assert output.crop in crops
    assert detector.invocation_count == 9  # Baseline plus 1+1+2+4 diagnostic invokes.
    assert detector.config.confidence_threshold == 0.55
