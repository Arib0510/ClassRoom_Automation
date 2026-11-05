"""Selected SSD strategy using existing preprocessing, transforms and NMS."""

from __future__ import annotations

import time

from .crops import ROI, CropPrediction, global_nms, make_crops
from .images import detection_record


class StrategyDetector:
    def __init__(self, adapter, strategy, clock=time.perf_counter):
        self.adapter, self.strategy, self.clock = adapter, strategy, clock

    def detect(self, frame):
        rgb = frame["rgb"]
        mode = "full" if self.strategy["mode"] == "single_pass" else self.strategy["mode"]
        size = (rgb.shape[1], rgb.shape[0])
        crops = make_crops(size, mode, ROI(*self.strategy["roi"]), self.strategy["overlap"])
        predictions = []
        times = dict(preprocessing_seconds=0.0, inference_seconds=0.0, postprocessing_seconds=0.0)
        # Time the real adapter stages without changing the established adapter.
        observer = TimedInterpreter(self.adapter.interpreter, self.clock)
        original = self.adapter.interpreter
        original_prepare = self.adapter.prepare

        def timed_prepare(rgb):
            before = self.clock()
            try:
                return original_prepare(rgb)
            finally:
                times["preprocessing_seconds"] += self.clock() - before

        self.adapter.prepare = timed_prepare
        self.adapter.interpreter = observer
        started = self.clock()
        try:
            for crop in crops:
                left, top, right, bottom = crop.pixels
                for detection in self.adapter.detect(
                    rgb[top:bottom, left:right], confidence_threshold=0.0
                ):
                    predictions.append(
                        CropPrediction(crop.reproject(detection), crop, detection.box)
                    )
        finally:
            self.adapter.interpreter = original
            self.adapter.prepare = original_prepare
        infer_end = self.clock()
        eligible = [
            p for p in predictions if p.detection.score >= self.adapter.config.confidence_threshold
        ]
        kept = (
            global_nms(eligible, self.strategy["nms_iou"])
            if mode in ("left_right", "overlap")
            else range(len(eligible))
        )
        selected = [eligible[i].detection for i in kept]
        ended = self.clock()
        # prepare and parse time are accounted separately by stage hooks below.
        times["inference_seconds"] = observer.invoke_seconds
        times["postprocessing_seconds"] = max(
            0, ended - started - times["inference_seconds"] - times["preprocessing_seconds"]
        )
        records = [
            detection_record(frame["frame_id"], i, detection, size)
            | {
                "frame_id": frame["frame_id"],
                "model_sha256": self.adapter.config.sha256,
                "strategy": self.strategy["mode"],
                "input_dimensions_wh": [300, 300],
                "original_dimensions_wh": list(size),
                **times,
            }
            for i, detection in enumerate(selected)
        ]
        return {
            "detections": selected,
            "records": records,
            "passes": len(crops),
            "timings": times,
            "strategy": self.strategy["mode"],
            "frame_id": frame["frame_id"],
            "total_detector_seconds": ended - started,
            "crop_invoke_and_parse_seconds": infer_end - started,
        }


class TimedInterpreter:
    """Kernel-only clock observer; original output parsing and input encoding are unchanged."""

    def __init__(self, interpreter, clock):
        self.delegate, self.clock = interpreter, clock
        self.invoke_seconds = 0.0

    def __getattr__(self, key):
        return getattr(self.delegate, key)

    def invoke(self):
        started = self.clock()
        try:
            return self.delegate.invoke()
        finally:
            ended = self.clock()
            self.invoke_seconds += ended - started
