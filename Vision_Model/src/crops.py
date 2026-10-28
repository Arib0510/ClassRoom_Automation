"""Experimental image crops, full-frame transforms and global NMS; no zone geometry."""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

from .detector import Detection, SSDAdapter

MODES = ("full", "roi", "left_right", "overlap")


@dataclass(frozen=True)
class ROI:
    """Normalized x_min,y_min,x_max,y_max in the oriented full image."""

    xmin: float = 0.0
    ymin: float = 0.0
    xmax: float = 1.0
    ymax: float = 1.0

    def __post_init__(self):
        values = (self.xmin, self.ymin, self.xmax, self.ymax)
        if (
            any(
                isinstance(v, bool)
                or not isinstance(v, (int, float))
                or not math.isfinite(v)
                or not 0 <= v <= 1
                for v in values
            )
            or self.xmin >= self.xmax
            or self.ymin >= self.ymax
        ):
            raise ValueError(
                "ROI requires finite normalized xmin,ymin,xmax,ymax with positive area"
            )


@dataclass(frozen=True)
class Crop:
    name: str
    pixels: tuple[int, int, int, int]  # left, top, right, bottom; right/bottom exclusive
    image_size: tuple[int, int]

    def __post_init__(self):
        width, height = self.image_size
        left, top, right, bottom = self.pixels
        if any(type(v) is not int for v in (*self.image_size, *self.pixels)) or not (
            0 <= left < right <= width and 0 <= top < bottom <= height
        ):
            raise ValueError("Crop needs positive integer bounds inside the source image")

    def reproject(self, detection: Detection) -> Detection:
        left, top, right, bottom = self.pixels
        width, height = self.image_size
        y0, x0, y1, x1 = detection.box
        return Detection(
            (
                (top + y0 * (bottom - top)) / height,
                (left + x0 * (right - left)) / width,
                (top + y1 * (bottom - top)) / height,
                (left + x1 * (right - left)) / width,
            ),
            detection.score,
            detection.class_id,
        )

    def metadata(self) -> dict:
        return {
            "name": self.name,
            "pixels_xyxy": list(self.pixels),
            "full_image_size": list(self.image_size),
        }


def make_crops(
    size: tuple[int, int], mode: str = "full", roi: ROI | None = None, overlap: float = 0.2
) -> list[Crop]:
    roi = ROI() if roi is None else roi
    width, height = size
    if any(isinstance(v, bool) or not isinstance(v, int) or v < 1 for v in size):
        raise ValueError("Image dimensions must be positive integers")
    if mode not in MODES:
        raise ValueError(f"Unknown crop mode: {mode}")
    if isinstance(overlap, bool) or not math.isfinite(overlap) or not 0 <= overlap < 0.9:
        raise ValueError("Overlap must be finite and in [0,0.9)")
    if mode == "full":
        regions = [("full", ROI())]
    elif mode == "roi":
        regions = [("roi", roi)]
    elif mode == "left_right":
        middle = (roi.xmin + roi.xmax) / 2
        regions = [
            ("left", ROI(roi.xmin, roi.ymin, middle, roi.ymax)),
            ("right", ROI(middle, roi.ymin, roi.xmax, roi.ymax)),
        ]
    else:
        dx = (roi.xmax - roi.xmin) / (2 - overlap)
        dy = (roi.ymax - roi.ymin) / (2 - overlap)
        regions = [
            (f"tile_{row}_{col}", ROI(x, y, min(roi.xmax, x + dx), min(roi.ymax, y + dy)))
            for row, y in enumerate((roi.ymin, roi.ymax - dy))
            for col, x in enumerate((roi.xmin, roi.xmax - dx))
        ]
    return [
        Crop(
            name,
            (
                math.floor(r.xmin * width),
                math.floor(r.ymin * height),
                math.ceil(r.xmax * width),
                math.ceil(r.ymax * height),
            ),
            size,
        )
        for name, r in regions
    ]


def box_iou(a: tuple, b: tuple) -> float:
    """IoU for normalized or pixel y_min,x_min,y_max,x_max boxes."""
    intersection = max(0, min(a[2], b[2]) - max(a[0], b[0])) * max(
        0, min(a[3], b[3]) - max(a[1], b[1])
    )
    area_a = (a[2] - a[0]) * (a[3] - a[1])
    area_b = (b[2] - b[0]) * (b[3] - b[1])
    union = area_a + area_b - intersection
    return intersection / union if union > 0 else 0.0


@dataclass(frozen=True)
class CropPrediction:
    detection: Detection
    crop: Crop
    local_box: tuple[float, float, float, float]


def global_nms(predictions: list[CropPrediction], iou_threshold: float = 0.5) -> list[int]:
    """Stable score-ordered class-aware suppression; retain winning box/score unchanged."""
    if not math.isfinite(iou_threshold) or not 0 < iou_threshold <= 1:
        raise ValueError("NMS IoU threshold must be in (0,1]")
    kept = []
    for index in sorted(range(len(predictions)), key=lambda i: -predictions[i].detection.score):
        detection = predictions[index].detection
        if not any(
            detection.class_id == predictions[j].detection.class_id
            and box_iou(detection.box, predictions[j].detection.box) >= iou_threshold
            for j in kept
        ):
            kept.append(index)
    return kept


def infer_crops(detector: SSDAdapter, rgb: np.ndarray, crops: list[Crop]) -> list[CropPrediction]:
    """Reuse one allocated interpreter, one crop view at a time; keep all returned persons."""
    if (detector.input_width, detector.input_height) != (300, 300):
        raise ValueError("This classroom experiment requires the reviewed native 300x300 input")
    result = []
    for crop in crops:
        if crop.image_size != (rgb.shape[1], rgb.shape[0]):
            raise ValueError("Crop dimensions differ from source frame")
        left, top, right, bottom = crop.pixels
        for detection in detector.detect(rgb[top:bottom, left:right], confidence_threshold=0.0):
            result.append(CropPrediction(crop.reproject(detection), crop, detection.box))
    return result
