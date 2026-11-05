"""Offline-only model records; heavyweight imports are lazy and isolated from production."""

from __future__ import annotations

import math
import os
import subprocess
import sys
from pathlib import Path
from typing import Protocol

import numpy as np

from .crops import box_iou
from .detector import Detection, ModelContractError
from .images import detection_record, load_rgb_image
from .person_labels import source_hash
from .phase3_diagnostics import select_predictions

REVISION = "915bbf294bb74c859f0b41f1c23bc395014ea679"
WEIGHT_SHA256 = "4f180cf23ba0717ada0badd6c685026d73d48f184d00fc159c2641284b2ac0a3"
MODEL_DIR = Path(__file__).resolve().parents[1] / "models/experimental/yolov5n"


class ExperimentalDetector(Protocol):
    model_id: str

    def predict(self, path: Path) -> tuple[list[dict], dict]: ...


def probability(value: float, name: str = "threshold") -> float:
    if isinstance(value, bool) or not math.isfinite(value) or not 0 <= value <= 1:
        raise ValueError(f"{name} must be finite in [0,1]")
    return value


def reverse_letterbox(boxes: np.ndarray, size: tuple, ratio: tuple, pad: tuple) -> np.ndarray:
    """Undo the exact official letterbox ratio and fractional padding, without rounding."""
    boxes = np.asarray(boxes, dtype=np.float64).copy()
    if boxes.ndim != 2 or boxes.shape[1] != 4 or not np.isfinite(boxes).all():
        raise ModelContractError("Expected finite [N,4] xyxy boxes")
    if any(not math.isfinite(v) or v <= 0 for v in (*size, *ratio)) or any(
        not math.isfinite(v) or v < 0 for v in pad
    ):
        raise ValueError("Invalid letterbox transform")
    boxes[:, [0, 2]] = np.clip((boxes[:, [0, 2]] - pad[0]) / ratio[0], 0, size[0])
    boxes[:, [1, 3]] = np.clip((boxes[:, [1, 3]] - pad[1]) / ratio[1], 0, size[1])
    return boxes


def person_candidates(raw: np.ndarray, threshold: float, person_id: int) -> np.ndarray:
    """v7 decoded [1,N,85]: xywh pixels, objectness, 80 class probabilities.

    Match official single-label selection: best class first, then person filter.
    Inclusive threshold; preserve continuous box edges and objectness*class score.
    """
    probability(threshold)
    raw = np.asarray(raw)
    if raw.ndim != 3 or raw.shape[0] != 1 or raw.shape[2] != 85:
        raise ModelContractError("YOLOv5 COCO decoded output must be [1,N,85]")
    if not np.isfinite(raw).all() or (raw[..., 2:4] < 0).any():
        raise ModelContractError("Invalid YOLO geometry")
    if ((raw[..., 4:] < 0) | (raw[..., 4:] > 1)).any():
        raise ModelContractError("Invalid YOLO probabilities")
    if type(person_id) is not int or not 0 <= person_id < 80:
        raise ModelContractError("Invalid verified person class")
    rows = raw[0]
    classes = rows[:, 5:].argmax(axis=1)
    scores = rows[:, 4] * rows[np.arange(len(rows)), 5 + classes]
    keep = (classes == person_id) & (scores >= threshold)
    xywh = rows[keep, :4]
    boxes = np.column_stack((xywh[:, :2] - xywh[:, 2:] / 2, xywh[:, :2] + xywh[:, 2:] / 2))
    return np.column_stack((boxes, scores[keep], classes[keep]))


def person_nms(candidates: np.ndarray, iou: float = 0.45, max_det: int = 300) -> list[int]:
    probability(iou, "NMS IoU")
    if iou == 0 or type(max_det) is not int or max_det <= 0:
        raise ValueError("NMS needs positive IoU and max_det")
    rows = np.asarray(candidates)
    if rows.ndim != 2 or rows.shape[1] != 6 or not np.isfinite(rows).all():
        raise ModelContractError("NMS expects finite [N,6]")
    kept = []
    # Same > IoU suppression boundary as torchvision, stable ordering for ties.
    for index in sorted(range(len(rows)), key=lambda i: -rows[i, 4]):
        if not any(
            rows[index, 5] == rows[j, 5]
            and box_iou(tuple(rows[index, [1, 0, 3, 2]]), tuple(rows[j, [1, 0, 3, 2]])) > iou
            for j in kept
        ):
            kept.append(index)
            if len(kept) == max_det:
                break
    return kept


def prediction_records(rows: np.ndarray, filename: str, model_id: str, metadata: dict) -> list:
    size = tuple(metadata["original_size_wh"])
    boxes = reverse_letterbox(rows[:, :4], size, metadata["ratio_xy"], metadata["pad_xy"])
    records = []
    for row, (x0, y0, x1, y1) in zip(rows, boxes, strict=True):
        if x0 >= x1 or y0 >= y1:
            continue  # A box entirely in padding has no source-image area.
        detection = Detection(
            (y0 / size[1], x0 / size[0], y1 / size[1], x1 / size[0]), float(row[4]), int(row[5])
        )
        records.append(
            detection_record(filename, len(records), detection, size)
            | {
                "model_id": model_id,
                "original_image_dimensions_wh": list(size),
                "inference_input_dimensions_wh": metadata["input_size_wh"],
                "preprocessing": metadata,
            }
        )
    return records


class CachedSSD:
    """Reuse Phase 3 returned outputs and its unchanged crop selection/NMS rules."""

    def __init__(self, cache: dict, mode: str, threshold: float):
        probability(threshold)
        self.model_id = f"ssd_{mode}"
        self.cache, self.mode, self.threshold = cache, mode, threshold

    def predict(self, path: Path) -> tuple[list[dict], dict]:
        image = next(i for i in self.cache["images"] if i["file_name"] == path.name)
        rows, suppressed = select_predictions(
            image["modes"][self.mode]["person_outputs"],
            self.mode,
            self.threshold,
            self.cache["settings"]["nms_iou"],
        )
        metadata = {
            "resize": "bilinear stretch",
            "encoding": "raw RGB uint8",
            "crop_mode": self.mode,
            "input_size_wh": [300, 300],
            "invocations": image["modes"][self.mode]["invocations"],
        }
        return [
            dict(
                r,
                model_id=self.model_id,
                original_image_dimensions_wh=[image["width"], image["height"]],
                inference_input_dimensions_wh=[300, 300],
                preprocessing=metadata,
            )
            for r in rows
        ], dict(metadata, suppressed=suppressed)


def verify_artifacts(folder: Path) -> None:
    weight = folder / "yolov5n.pt"
    if not weight.is_file() or source_hash(weight) != WEIGHT_SHA256:
        raise ModelContractError(
            "Missing or mismatched YOLOv5n weights; run scripts/fetch_yolov5.py"
        )
    source = folder / "source"
    if not (source / "models/yolo.py").is_file():
        raise ModelContractError("Missing official source")
    revision = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True)
    dirty = subprocess.check_output(["git", "-C", str(source), "diff", "HEAD", "--"], text=True)
    if revision.strip() != REVISION or dirty.strip():
        raise ModelContractError("Source revision or tracked source bytes differ from pin")


class YOLOv5n:
    def __init__(self, size: int, folder: Path = MODEL_DIR, threshold: float = 0.10):
        if type(size) is not int or size not in (320, 416):
            raise ValueError("Initial comparison supports exactly 320 or 416 square input")
        probability(threshold)
        verify_artifacts(folder)
        os.environ["YOLOv5_AUTOINSTALL"] = "false"
        # Upstream defaults may write plotting config outside this repository.
        os.environ["YOLOV5_CONFIG_DIR"] = str(folder.resolve() / "runtime_config")
        os.environ["MPLCONFIGDIR"] = str(folder.resolve() / "runtime_config/matplotlib")
        sys.path.insert(0, str((folder / "source").resolve()))
        import torch
        from utils.augmentations import letterbox

        from models.experimental import attempt_load

        torch.set_num_threads(2)
        self.torch, self.letterbox = torch, letterbox
        # Only the hash-verified official pickle is deserialized; no hub or downloads.
        self.model = attempt_load(str(folder / "yolov5n.pt"), device=torch.device("cpu"))
        names = (
            dict(enumerate(self.model.names))
            if isinstance(self.model.names, list)
            else self.model.names
        )
        ids = [i for i, name in names.items() if name == "person"]
        if len(names) != 80 or ids != [0] or int(self.model.stride.max()) != 32:
            raise ModelContractError(
                "Checkpoint label map/stride differs from reviewed COCO contract"
            )
        self.person_id = ids[0]
        self.names = names
        self.size, self.threshold = size, threshold
        self.model_id = f"yolov5n_{size}"
        self.invocations = 0
        self.last_raw = None
        self.last_candidates = None

    def prepare(self, path: Path):
        loaded = load_rgb_image(path)
        # Pillow already returns RGB; cv2.resize/padding do not swap channels.
        padded, ratio, pad = self.letterbox(
            loaded.rgb, (self.size, self.size), auto=False, scaleFill=False, scaleup=True, stride=32
        )
        tensor = self.torch.from_numpy(np.ascontiguousarray(padded.transpose(2, 0, 1)))
        tensor = tensor.float().unsqueeze(0) / 255.0
        metadata = {
            "original_size_wh": list(loaded.image.size),
            "encoded_size_wh": list(loaded.encoded_size),
            "exif_orientation": loaded.exif_orientation,
            "input_size_wh": [self.size, self.size],
            "ratio_xy": list(ratio),
            "pad_xy": list(pad),
            "color": "RGB (Pillow; no BGR source)",
            "resize": "official cv2 INTER_LINEAR letterbox; auto=False; scaleFill=False",
            "padding_rgb": [114, 114, 114],
            "scaleup": True,
            "layout": "NCHW float32 /255",
            "nms_iou": 0.45,
            "confidence_floor": self.threshold,
            "single_label": True,
            "max_det": 300,
            "coordinate_rounding": "none",
        }
        return tensor, metadata

    def predict(self, path: Path) -> tuple[list[dict], dict]:
        tensor, metadata = self.prepare(path)
        with self.torch.inference_mode():
            raw = self.model(tensor)[0].cpu().numpy()
        self.invocations += 1
        expected = 3 * sum((self.size // s) ** 2 for s in (8, 16, 32))
        if raw.shape != (1, expected, 85):
            raise ModelContractError(f"Unexpected decoded output shape: {raw.shape}")
        self.last_raw = raw.copy()
        candidates = person_candidates(raw, self.threshold, self.person_id)
        self.last_candidates = candidates.copy()
        rows = candidates[person_nms(candidates)]
        return prediction_records(rows, path.name, self.model_id, metadata), metadata
