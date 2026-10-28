"""Genuine SSD kernels through the Phase 5 strategy wrapper; no camera or MQTT."""

import pytest

from src.config import REPO_ROOT, load_config
from src.crops import ROI, infer_crops, make_crops
from src.detector import create_detector
from src.images import load_rgb_image
from src.phase5_vision import StrategyDetector

pytestmark = pytest.mark.real_inference


@pytest.mark.parametrize("mode", ["single_pass", "roi", "left_right", "overlap"])
def test_phase5_real_ssd_matches_existing_adapter_and_crop_geometry(mode):
    adapter = create_detector(load_config().detector, backend="tensorflow")
    loaded = load_rgb_image(REPO_ROOT / "sample_images/IMG_20261013_133640.jpg")
    strategy = {"mode": mode, "roi": [0, 0.2, 1, 1], "overlap": 0.2, "nms_iou": 0.5}
    frame = {"frame_id": "real-image", "rgb": loaded.rgb}
    original_prepare, original_interpreter = adapter.prepare, adapter.interpreter
    actual = StrategyDetector(adapter, strategy).detect(frame)
    mapped_mode = "full" if mode == "single_pass" else mode
    original = infer_crops(
        adapter, loaded.rgb, make_crops(loaded.image.size, mapped_mode, ROI(0, 0.2, 1, 1), 0.2)
    )
    eligible = [p for p in original if p.detection.score >= adapter.config.confidence_threshold]
    if mode in ("left_right", "overlap"):
        from src.crops import global_nms

        eligible = [eligible[i] for i in global_nms(eligible, 0.5)]
    assert actual["detections"] == [p.detection for p in eligible]
    assert adapter.interpreter is original_interpreter and adapter.prepare == original_prepare
    assert actual["passes"] == {"single_pass": 1, "roi": 1, "left_right": 2, "overlap": 4}[mode]
    assert actual["timings"]["inference_seconds"] > 0
    assert adapter.config.confidence_threshold == 0.55
