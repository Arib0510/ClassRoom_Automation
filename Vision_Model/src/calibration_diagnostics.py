"""Reproducible confidence/NMS calibration for reviewed classroom images.

This command is intentionally diagnostic-only.  It evaluates two explicitly
named YOLO checkpoints on the same reviewed images, keeps raw detector outputs
separate for every NMS setting, and never changes production configuration,
annotations, weights, or datasets.
"""

# The report contains intentionally long, human-readable diagnostic sentences.
# Keep ordinary code checks active while allowing those report literals.
# ruff: noqa: E501

from __future__ import annotations

import argparse
import csv
import json
import math
import re
from pathlib import Path
from typing import Any

import cv2
import numpy as np

from .offline_diagnostics import detect_frame, load_model, sha256_file
from .person_labels import annotation_box, match_image, validate_labels

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CONFIDENCES = (0.20, 0.28, 0.35, 0.40, 0.45, 0.50, 0.60)
DEFAULT_NMS_IOUS = (0.30, 0.40, 0.45, 0.50, 0.60)
MATCHING_IOU = 0.50
MIN_INFERENCE_CONFIDENCE = min(DEFAULT_CONFIDENCES)
DIAGNOSTIC_LABEL = (
    "Diagnostic evaluation: images share the training capture sequence; not an independent test."
)
FRAME_RE = re.compile(r"-(\d+)(?:_clean)?(?:\s*-\s*Copy)?(?:\.[^.]+)?$", re.IGNORECASE)
IMAGE_EXTENSIONS = {".bmp", ".jpeg", ".jpg", ".png"}


def _write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n", encoding="utf-8")


def _slug(value: str) -> str:
    return value.replace(".", "p").replace("-", "m")


def _config_id(model_id: str, confidence: float, nms_iou: float) -> str:
    return f"{model_id}__conf_{confidence:.2f}__nms_{nms_iou:.2f}"


def _float_list(values: tuple[float, ...]) -> list[float]:
    return [float(value) for value in values]


def _validate_sweep(values: tuple[float, ...], name: str, *, allow_zero: bool = False) -> None:
    for value in values:
        if not math.isfinite(value) or (value < 0 if allow_zero else value <= 0) or value > 1:
            raise ValueError(f"{name} values must be finite and in (0,1]")


def _match_prediction_row(detection: dict[str, Any]) -> dict[str, Any]:
    """Adapt detector xyxy-normalized records to the existing label matcher."""
    x1, y1, x2, y2 = [float(value) for value in detection["normalized_xyxy"]]
    return {
        "xmin_normalized": x1,
        "ymin_normalized": y1,
        "xmax_normalized": x2,
        "ymax_normalized": y2,
        "confidence": float(detection["confidence"]),
    }


def verify_coordinate_conversion(
    detections: list[dict[str, Any]], width: int, height: int, tolerance: float = 1e-6
) -> None:
    """Fail closed if pixel and normalized detector coordinates disagree."""
    if width <= 0 or height <= 0:
        raise ValueError("Image dimensions must be positive")
    for index, detection in enumerate(detections):
        pixels = detection.get("xyxy")
        normalized = detection.get("normalized_xyxy")
        if not isinstance(pixels, list) or not isinstance(normalized, list) or len(pixels) != 4:
            raise ValueError(f"Detection {index} is missing xyxy coordinate records")
        expected = [pixels[0] / width, pixels[1] / height, pixels[2] / width, pixels[3] / height]
        if any(
            abs(float(a) - float(b)) > tolerance for a, b in zip(expected, normalized, strict=False)
        ):
            raise ValueError(f"Detection {index} failed pixel/normalized coordinate round-trip")
        if not (
            0 <= normalized[0] <= normalized[2] <= 1 and 0 <= normalized[1] <= normalized[3] <= 1
        ):
            raise ValueError(f"Detection {index} has invalid normalized xyxy bounds")


def _load_review_inventory(input_dir: Path, labels_path: Path) -> tuple[list[dict], dict, dict]:
    paths = sorted(
        [
            path
            for path in input_dir.iterdir()
            if path.is_file() and path.suffix.lower() in IMAGE_EXTENSIONS
        ],
        key=lambda path: (path.name.casefold(), path.name),
    )
    if not paths:
        raise ValueError(f"No supported review images in: {input_dir}")
    labels = json.loads(labels_path.read_text(encoding="utf-8"))
    inventory = []
    for index, path in enumerate(paths, 1):
        image = cv2.imread(str(path), cv2.IMREAD_COLOR)
        if image is None:
            raise ValueError(f"Could not read review image: {path}")
        inventory.append(
            {
                "id": index,
                "file_name": path.name,
                "width": int(image.shape[1]),
                "height": int(image.shape[0]),
                "source_sha256": sha256_file(path),
                "reviewed": True,
                "reviewed_by": "calibration_preflight",
            }
        )
    # validate_labels checks the source image hashes and dimensions against COCO.
    if not validate_labels(labels, inventory):
        raise ValueError("Calibration requires every review image to be fully human-reviewed")
    label_images = {image["file_name"]: image for image in labels["images"]}
    annotations = {}
    for image_name, image in label_images.items():
        annotations[image_name] = [
            annotation
            for annotation in labels.get("annotations", [])
            if annotation["image_id"] == image["id"]
        ]
    return inventory, label_images, annotations


def _cache_matches(
    document: dict,
    *,
    model_id: str,
    model_path: Path,
    model_sha256: str,
    image_hashes: dict[str, str],
    confidence: float,
    nms_iou: float,
    imgsz: int,
) -> bool:
    metadata = document.get("metadata", {})
    return (
        document.get("status") == "completed"
        and metadata.get("model_id") == model_id
        and metadata.get("model_path") == str(model_path)
        and metadata.get("model_sha256") == model_sha256
        and metadata.get("image_sha256") == image_hashes
        and metadata.get("inference_confidence") == confidence
        and metadata.get("nms_iou") == nms_iou
        and metadata.get("imgsz") == imgsz
        and len(document.get("frames", [])) == len(image_hashes)
    )


def _raw_cache_path(output: Path, model_id: str, nms_iou: float) -> Path:
    return output / "raw_inference" / model_id / f"nms_{nms_iou:.2f}.json"


def _run_raw_inference(
    *,
    model: Any,
    model_id: str,
    model_path: Path,
    model_sha256: str,
    inventory: list[dict],
    input_dir: Path,
    output: Path,
    nms_iou: float,
    imgsz: int,
) -> dict:
    image_hashes = {item["file_name"]: item["source_sha256"] for item in inventory}
    cache_path = _raw_cache_path(output, model_id, nms_iou)
    if cache_path.is_file():
        try:
            cached = json.loads(cache_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            cached = {}
        if _cache_matches(
            cached,
            model_id=model_id,
            model_path=model_path,
            model_sha256=model_sha256,
            image_hashes=image_hashes,
            confidence=MIN_INFERENCE_CONFIDENCE,
            nms_iou=nms_iou,
            imgsz=imgsz,
        ):
            print(
                f"RESUME raw {model_id} nms={nms_iou:.2f} ({len(cached['frames'])} images)",
                flush=True,
            )
            return cached

    frames = []
    for position, item in enumerate(inventory, 1):
        path = input_dir / item["file_name"]
        frame = cv2.imread(str(path), cv2.IMREAD_COLOR)
        if frame is None:
            raise ValueError(f"Could not read review image during inference: {path}")
        detections = detect_frame(
            model, frame, conf=MIN_INFERENCE_CONFIDENCE, iou=nms_iou, imgsz=imgsz
        )
        verify_coordinate_conversion(detections, frame.shape[1], frame.shape[0])
        frames.append(
            {
                "file": item["file_name"],
                "source_sha256": item["source_sha256"],
                "width": int(frame.shape[1]),
                "height": int(frame.shape[0]),
                "detections": detections,
            }
        )
        print(
            f"{model_id} nms={nms_iou:.2f}: {position}/{len(inventory)} "
            f"{item['file_name']} detections={len(detections)}",
            flush=True,
        )
    document = {
        "status": "completed",
        "diagnostic_label": DIAGNOSTIC_LABEL,
        "metadata": {
            "model_id": model_id,
            "model_path": str(model_path),
            "model_sha256": model_sha256,
            "image_sha256": image_hashes,
            "inference_confidence": MIN_INFERENCE_CONFIDENCE,
            "nms_iou": nms_iou,
            "imgsz": imgsz,
            "tracking_used": False,
            "source_kind": "raw review image folder",
            "coordinate_system": "xyxy pixels plus normalized [x1,y1,x2,y2]",
            "nms_policy": "fresh Ultralytics inference for every NMS IoU; no post-NMS simulation",
        },
        "frames": frames,
    }
    _write_json(cache_path, document)
    return document


def _iou(a: list[float], b: list[float]) -> float:
    x1, y1 = max(a[0], b[0]), max(a[1], b[1])
    x2, y2 = min(a[2], b[2]), min(a[3], b[3])
    intersection = max(0.0, x2 - x1) * max(0.0, y2 - y1)
    area_a = max(0.0, a[2] - a[0]) * max(0.0, a[3] - a[1])
    area_b = max(0.0, b[2] - b[0]) * max(0.0, b[3] - b[1])
    union = area_a + area_b - intersection
    return intersection / union if union else 0.0


def _evaluate_config(
    *,
    model_id: str,
    model_path: Path,
    model_sha256: str,
    raw: dict,
    confidence: float,
    nms_iou: float,
    inventory: list[dict],
    label_images: dict,
    annotations: dict,
    output: Path,
) -> dict:
    config_id = _config_id(model_id, confidence, nms_iou)
    config_path = (
        output / "configurations" / model_id / f"conf_{confidence:.2f}__nms_{nms_iou:.2f}.json"
    )
    image_hashes = {item["file_name"]: item["source_sha256"] for item in inventory}
    if config_path.is_file():
        try:
            cached = json.loads(config_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            cached = {}
        if (
            cached.get("status") == "completed"
            and cached.get("metadata", {}).get("model_sha256") == model_sha256
            and cached.get("metadata", {}).get("image_sha256") == image_hashes
            and cached.get("metadata", {}).get("confidence") == confidence
            and cached.get("metadata", {}).get("nms_iou") == nms_iou
            and len(cached.get("frames", [])) == len(inventory)
        ):
            cached["config_id"] = config_id
            cached.setdefault("summary", {})["config_id"] = config_id
            for frame in cached.get("frames", []):
                frame.setdefault("metrics", {})["frame_number"] = _frame_number(frame["file"])
            _write_json(config_path, cached)
            print(f"RESUME config {config_id}", flush=True)
            return cached

    frame_results = []
    totals = {
        "TP": 0,
        "FP": 0,
        "FN": 0,
        "ignored_uncertain_predictions": 0,
        "duplicate_candidates": 0,
        "certain_ground_truth": 0,
        "seated_ground_truth": 0,
        "seated_matched": 0,
        "partial_ground_truth": 0,
        "partial_matched": 0,
        "signed_count_bias_sum": 0,
        "absolute_count_error_sum": 0,
    }
    for raw_frame, item in zip(raw["frames"], inventory, strict=True):
        if (
            raw_frame["file"] != item["file_name"]
            or raw_frame["source_sha256"] != item["source_sha256"]
        ):
            raise ValueError(f"Raw cache does not match review inventory: {item['file_name']}")
        detections = [
            detection
            for detection in raw_frame.get("detections", [])
            if float(detection["confidence"]) >= confidence and int(detection["class_id"]) == 0
        ]
        # Explicitly retain an empty detections list in every frame record.
        match_rows = [_match_prediction_row(detection) for detection in detections]
        image_info = label_images[item["file_name"]]
        image_annotations = annotations[item["file_name"]]
        metrics = match_image(match_rows, image_annotations, image_info, MATCHING_IOU)
        certain_annotations = [
            annotation
            for annotation in image_annotations
            if not annotation["attributes"]["uncertain"]
        ]
        matched_ids = set(metrics["matched_annotation_ids"])
        seated = [
            annotation for annotation in certain_annotations if annotation["attributes"]["seated"]
        ]
        partial = [
            annotation for annotation in certain_annotations if annotation["attributes"]["partial"]
        ]
        ignored = set(metrics["uncertain_ignored_prediction_indices"])
        scored_prediction_count = len(detections) - len(ignored)
        count_delta = scored_prediction_count - len(certain_annotations)
        duplicate_rows = []
        for prediction_index in metrics["false_positive_prediction_indices"]:
            prediction_box = detections[prediction_index]["normalized_xyxy"]
            overlaps = [
                (_iou(prediction_box, annotation_box(annotation, image_info)), annotation["id"])
                for annotation in certain_annotations
            ]
            best_iou, best_id = max(overlaps, default=(0.0, None))
            if best_iou >= MATCHING_IOU:
                duplicate_rows.append(
                    {
                        "prediction_index": prediction_index,
                        "confidence": float(detections[prediction_index]["confidence"]),
                        "matched_person_annotation_id": best_id,
                        "iou_to_already_matched_person": best_iou,
                        "classification": "duplicate_candidate_only_requires_visual_review",
                    }
                )
        frame_metrics = {
            "file_name": item["file_name"],
            "frame_number": _frame_number(item["file_name"]),
            "source_sha256": item["source_sha256"],
            "certain_ground_truth": len(certain_annotations),
            "uncertain_ground_truth": len(image_annotations) - len(certain_annotations),
            "seated_ground_truth": len(seated),
            "seated_matched": sum(annotation["id"] in matched_ids for annotation in seated),
            "partial_ground_truth": len(partial),
            "partial_matched": sum(annotation["id"] in matched_ids for annotation in partial),
            "predictions": len(detections),
            "scored_predictions": scored_prediction_count,
            "ignored_uncertain_predictions": len(ignored),
            "TP": metrics["true_positives"],
            "FP": metrics["false_positives"],
            "FN": metrics["false_negatives"],
            "absolute_count_error": abs(count_delta),
            "signed_count_delta": count_delta,
            "duplicate_candidates": len(duplicate_rows),
            "matched_annotation_ids": sorted(matched_ids),
            "false_negative_annotation_ids": metrics["false_negative_annotation_ids"],
            "false_positive_prediction_indices": metrics["false_positive_prediction_indices"],
            "duplicate_candidate_rows": duplicate_rows,
        }
        frame_results.append(
            {
                "file": item["file_name"],
                "source_sha256": item["source_sha256"],
                "width": item["width"],
                "height": item["height"],
                "detections": detections,
                "metrics": frame_metrics,
            }
        )
        totals["TP"] += metrics["true_positives"]
        totals["FP"] += metrics["false_positives"]
        totals["FN"] += metrics["false_negatives"]
        totals["ignored_uncertain_predictions"] += len(ignored)
        totals["duplicate_candidates"] += len(duplicate_rows)
        totals["certain_ground_truth"] += len(certain_annotations)
        totals["seated_ground_truth"] += len(seated)
        totals["seated_matched"] += frame_metrics["seated_matched"]
        totals["partial_ground_truth"] += len(partial)
        totals["partial_matched"] += frame_metrics["partial_matched"]
        totals["signed_count_bias_sum"] += count_delta
        totals["absolute_count_error_sum"] += abs(count_delta)

    denominator = totals["TP"] + totals["FP"]
    recall_denominator = totals["TP"] + totals["FN"]
    precision = totals["TP"] / denominator if denominator else 0.0
    recall = totals["TP"] / recall_denominator if recall_denominator else 0.0
    f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
    image_count = len(frame_results)
    summary = {
        "model_id": model_id,
        "config_id": config_id,
        "model_path": str(model_path),
        "model_sha256": model_sha256,
        "confidence": confidence,
        "nms_iou": nms_iou,
        "imgsz": raw["metadata"]["imgsz"],
        "tracking_used": False,
        "matching_iou": MATCHING_IOU,
        "diagnostic_label": DIAGNOSTIC_LABEL,
        "TP": totals["TP"],
        "FP": totals["FP"],
        "FN": totals["FN"],
        "precision": precision,
        "recall": recall,
        "F1": f1,
        "count_MAE": totals["absolute_count_error_sum"] / image_count if image_count else 0.0,
        "signed_count_bias": totals["signed_count_bias_sum"] / image_count if image_count else 0.0,
        "duplicate_candidates": totals["duplicate_candidates"],
        "duplicate_rate": totals["duplicate_candidates"] / denominator if denominator else 0.0,
        "seated_ground_truth": totals["seated_ground_truth"],
        "seated_matched": totals["seated_matched"],
        "seated_recall": (
            totals["seated_matched"] / totals["seated_ground_truth"]
            if totals["seated_ground_truth"]
            else 0.0
        ),
        "partial_ground_truth": totals["partial_ground_truth"],
        "partial_matched": totals["partial_matched"],
        "partial_recall": (
            totals["partial_matched"] / totals["partial_ground_truth"]
            if totals["partial_ground_truth"]
            else 0.0
        ),
        "ignored_uncertain_predictions": totals["ignored_uncertain_predictions"],
        "images_evaluated": image_count,
    }
    document = {
        "status": "completed",
        "config_id": config_id,
        "diagnostic_label": DIAGNOSTIC_LABEL,
        "metadata": {
            **summary,
            "image_sha256": {item["file_name"]: item["source_sha256"] for item in inventory},
            "uncertain_policy": (
                "Uncertain GT is excluded from TP/FN and count denominators. A prediction "
                "overlapping only uncertain GT at IoU >= 0.50 is ignored."
            ),
            "matching_rule": "Confidence-sorted greedy one-to-one matching at fixed IoU 0.50",
            "duplicate_policy": (
                "Unmatched predictions overlapping a certain GT at IoU >= 0.50 are candidates "
                "only; this is not a visual duplicate verdict."
            ),
        },
        "summary": summary,
        "frames": frame_results,
    }
    _write_json(config_path, document)
    return document


def _frame_number(file_name: str) -> int | None:
    match = FRAME_RE.search(file_name)
    return int(match.group(1)) if match else None


def _select_candidates(summaries: list[dict]) -> dict[str, dict | None]:
    best_f1 = max(summaries, key=lambda row: (row["F1"], row["recall"], -row["count_MAE"]))
    best_count = min(summaries, key=lambda row: (row["count_MAE"], -row["F1"], -row["recall"]))
    recall_rows = [row for row in summaries if row["recall"] >= 0.90]
    best_recall = (
        min(recall_rows, key=lambda row: (row["FP"], -row["recall"], -row["F1"]))
        if recall_rows
        else None
    )
    return {
        "best_f1": best_f1,
        "lowest_count_MAE": best_count,
        "recall_at_least_0.90_fewest_FP": best_recall,
    }


def _summary_csv_rows(summaries: list[dict]) -> list[dict]:
    fields = [
        "model_id",
        "config_id",
        "confidence",
        "nms_iou",
        "TP",
        "FP",
        "FN",
        "precision",
        "recall",
        "F1",
        "count_MAE",
        "signed_count_bias",
        "duplicate_candidates",
        "seated_recall",
        "partial_recall",
        "model_sha256",
        "diagnostic_label",
    ]
    return [
        {field: summary.get(field, summary.get("config_id")) for field in fields}
        for summary in summaries
    ]


def _write_csv(path: Path, rows: list[dict], fieldnames: list[str] | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not fieldnames:
        fieldnames = list(rows[0]) if rows else []
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def _write_per_image_csv(path: Path, documents: list[dict]) -> None:
    rows = []
    for document in documents:
        for frame in document["frames"]:
            rows.append(
                {
                    "model_id": document["summary"]["model_id"],
                    **document["summary"],
                    **frame["metrics"],
                }
            )
    _write_csv(path, rows)


def _draw_label(
    image: np.ndarray, box: list[float], color: tuple[int, int, int], label: str
) -> None:
    x1, y1, x2, y2 = [round(float(value)) for value in box]
    cv2.rectangle(image, (x1, y1), (x2, y2), color, 3)
    cv2.putText(image, label, (x1, max(18, y1 - 7)), cv2.FONT_HERSHEY_SIMPLEX, 0.55, color, 2)


def _render_overlay(
    *,
    image_path: Path,
    document: dict,
    frame: dict,
    label_image: dict,
    annotations: list[dict],
    title: str,
    output_path: Path,
) -> None:
    image = cv2.imread(str(image_path), cv2.IMREAD_COLOR)
    if image is None:
        raise ValueError(f"Could not read overlay image: {image_path}")
    width = image.shape[1]
    metrics = frame["metrics"]
    matched = set(metrics["matched_annotation_ids"])
    false_positive = set(metrics["false_positive_prediction_indices"])
    duplicate = {row["prediction_index"] for row in metrics["duplicate_candidate_rows"]}
    for annotation in annotations:
        box = annotation["bbox"]
        x, y, w, h = box
        color = (
            (0, 165, 255)
            if annotation["attributes"]["uncertain"]
            else ((0, 220, 0) if annotation["id"] in matched else (0, 0, 255))
        )
        _draw_label(
            image,
            [x, y, x + w, y + h],
            color,
            f"GT {annotation['id']} " + ("MATCHED" if annotation["id"] in matched else "MISSED"),
        )
    for index, detection in enumerate(frame["detections"]):
        if index in duplicate:
            color, prefix = (255, 0, 255), "PRED DUP-CAND"
        elif index in false_positive:
            color, prefix = (0, 165, 255), "PRED FP"
        else:
            color, prefix = (0, 220, 0), "PRED TP"
        _draw_label(image, detection["xyxy"], color, f"{prefix} {detection['confidence']:.3f}")
    banner = np.zeros((52, width, 3), dtype=np.uint8)
    cv2.putText(banner, title, (12, 22), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (255, 255, 255), 2)
    cv2.putText(
        banner,
        "Diagnostic only | GT green=matched red=missed orange=uncertain | magenta=duplicate candidate only",
        (12, 44),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.38,
        (210, 210, 210),
        1,
    )
    result = np.vstack([banner, image])
    output_path.parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(output_path), result)


def _write_overlays(
    *,
    output: Path,
    input_dir: Path,
    documents: dict[str, dict],
    label_images: dict,
    annotations: dict,
    candidates: dict[str, dict | None],
    inventory: list[dict],
) -> None:
    classroom_current_id = _config_id("classroom", 0.28, 0.45)
    selected = {key: value for key, value in candidates.items() if value is not None}
    if classroom_current_id in documents:
        selected["current_classroom"] = documents[classroom_current_id]["summary"]
    for candidate_name, summary in selected.items():
        config_id = summary["config_id"]
        document = documents[config_id]
        ranked = sorted(
            document["frames"],
            key=lambda frame: (
                -(
                    frame["metrics"]["absolute_count_error"] * 3
                    + frame["metrics"]["FP"]
                    + frame["metrics"]["FN"]
                ),
                frame["file"],
            ),
        )[:5]
        for frame in ranked:
            _render_overlay(
                image_path=input_dir / frame["file"],
                document=document,
                frame=frame,
                label_image=label_images[frame["file"]],
                annotations=annotations[frame["file"]],
                title=(
                    f"{candidate_name} | {config_id} | conf={summary['confidence']:.2f} "
                    f"nms={summary['nms_iou']:.2f} | {frame['file']}"
                ),
                output_path=output
                / "overlays"
                / "candidates"
                / candidate_name
                / frame["file"].replace(".png", ".jpg"),
            )

    current = documents.get(classroom_current_id)
    if current is not None:
        current_by_file = {frame["file"]: frame for frame in current["frames"]}
        for candidate_name, summary in selected.items():
            if summary["config_id"] == classroom_current_id:
                continue
            document = documents[summary["config_id"]]
            candidate_by_file = {frame["file"]: frame for frame in document["frames"]}
            regressions = []
            for item in inventory:
                candidate_frame = candidate_by_file[item["file_name"]]
                current_frame = current_by_file[item["file_name"]]
                candidate_score = (
                    candidate_frame["metrics"]["FP"] + candidate_frame["metrics"]["FN"]
                )
                current_score = current_frame["metrics"]["FP"] + current_frame["metrics"]["FN"]
                regressions.append((candidate_score - current_score, item["file_name"]))
            for _, file_name in sorted(regressions, reverse=True)[:3]:
                left = cv2.imread(str(input_dir / file_name), cv2.IMREAD_COLOR)
                if left is None:
                    continue
                left_frame = candidate_by_file[file_name]
                right_document = current
                right_frame = current_by_file[file_name]
                left_path = (
                    output
                    / "overlays"
                    / "comparison"
                    / candidate_name
                    / f"{Path(file_name).stem}__candidate.jpg"
                )
                right_path = (
                    output
                    / "overlays"
                    / "comparison"
                    / candidate_name
                    / f"{Path(file_name).stem}__current.jpg"
                )
                _render_overlay(
                    image_path=input_dir / file_name,
                    document=document,
                    frame=left_frame,
                    label_image=label_images[file_name],
                    annotations=annotations[file_name],
                    title=f"candidate {summary['config_id']} | {file_name}",
                    output_path=left_path,
                )
                _render_overlay(
                    image_path=input_dir / file_name,
                    document=right_document,
                    frame=right_frame,
                    label_image=label_images[file_name],
                    annotations=annotations[file_name],
                    title=f"current classroom conf=0.28 nms=0.45 | {file_name}",
                    output_path=right_path,
                )


def _average_hash(path: Path) -> np.ndarray:
    image = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)
    if image is None:
        raise ValueError(f"Could not read image for near-duplicate check: {path}")
    small = cv2.resize(image, (16, 16), interpolation=cv2.INTER_AREA)
    return small >= float(small.mean())


def _write_dataset_plan(
    output: Path, review_dir: Path, inventory: list[dict], dataset_root: Path
) -> dict:
    dataset_files = []
    for split in ("train", "val", "test"):
        image_dir = dataset_root / "images" / split
        if not image_dir.is_dir():
            continue
        for path in sorted(image_dir.iterdir(), key=lambda item: item.name.casefold()):
            if path.is_file() and path.suffix.lower() in IMAGE_EXTENSIONS:
                dataset_files.append(
                    {
                        "split": split,
                        "file_name": path.name,
                        "sha256": sha256_file(path),
                        "path": str(path.resolve()),
                    }
                )
    dataset_by_hash: dict[str, list[dict]] = {}
    dataset_by_stem: dict[str, list[dict]] = {}
    for item in dataset_files:
        dataset_by_hash.setdefault(item["sha256"], []).append(item)
        dataset_by_stem.setdefault(Path(item["file_name"]).stem.casefold(), []).append(item)
    review_rows = []
    near_duplicates = []
    for item in inventory:
        review_path = review_dir / item["file_name"]
        exact = dataset_by_hash.get(item["source_sha256"], [])
        filename_matches = dataset_by_stem.get(Path(item["file_name"]).stem.casefold(), [])
        review_hash = _average_hash(review_path)
        nearest = []
        for dataset_item in dataset_files:
            distance = int(
                np.count_nonzero(review_hash != _average_hash(Path(dataset_item["path"])))
            )
            if distance <= 12 and dataset_item["sha256"] != item["source_sha256"]:
                nearest.append({"distance": distance, **dataset_item})
        nearest.sort(key=lambda row: (row["distance"], row["file_name"]))
        for candidate in nearest[:5]:
            near_duplicates.append(
                {
                    "review_file": item["file_name"],
                    "review_sha256": item["source_sha256"],
                    "dataset_file": candidate["file_name"],
                    "dataset_split": candidate["split"],
                    "dataset_sha256": candidate["sha256"],
                    "average_hash_hamming_distance": candidate["distance"],
                    "requires_human_review": True,
                }
            )
        review_rows.append(
            {
                "review_file": item["file_name"],
                "review_sha256": item["source_sha256"],
                "exact_hash_dataset_matches": exact,
                "filename_stem_dataset_matches": filename_matches,
                "same_capture_session": True,
            }
        )
    plan = {
        "diagnostic_label": DIAGNOSTIC_LABEL,
        "dataset_root": str(dataset_root.resolve()),
        "review_set": {
            "images": len(inventory),
            "session": "classroom_fa6cd2f8",
            "independent": False,
        },
        "existing_dataset": {
            "splits_found": sorted({item["split"] for item in dataset_files}),
            "image_count": len(dataset_files),
            "exact_hash_match_count": sum(
                bool(row["exact_hash_dataset_matches"]) for row in review_rows
            ),
            "filename_stem_match_count": sum(
                bool(row["filename_stem_dataset_matches"]) for row in review_rows
            ),
            "all_known_capture_session": "classroom_fa6cd2f8",
        },
        "review_rows": review_rows,
        "near_duplicate_candidates": near_duplicates,
        "near_duplicate_policy": "Average-hash candidates are leads for human review, never automatic split assignments.",
        "recommended_split_plan": [
            "Reserve at least one genuinely independent capture session, with complete manual labels, as the untouched test set.",
            "Group all frames from each capture session into exactly one split; do not split neighboring frames across train/validation/test.",
            "Use exact SHA-256 checks on the raw files and filename/session checks after any JPEG/PNG export.",
            "Review all average-hash near-duplicate candidates before finalizing split membership.",
            "After the independent session is reserved, the remaining reviewed labels may be added to training or validation by session, never by frame-level randomization.",
        ],
        "limitations": [
            "The current 40-image review set shares capture session classroom_fa6cd2f8 with the existing train/validation data.",
            "No independent test session is present in the current manifests; calibration metrics are diagnostic only.",
            "The current data.yaml has train and val entries but no test entry.",
        ],
        "capture_and_annotation_checklist": [
            "Capture multiple sessions on different days, lighting conditions, seating layouts, and occupancy levels.",
            "Keep each session in one directory and record camera placement, orientation, resolution, and timestamps.",
            "Sample frames with a gap large enough to avoid adjacent-frame leakage; keep a session manifest.",
            "Manually box every visible person, including seated and partial people, and record uncertain/partial/seated flags.",
            "Validate dimensions, source SHA-256, box bounds, duplicate boxes, and reviewer completion before scoring.",
            "Hold out the independent test session before any threshold/NMS selection or retraining.",
        ],
    }
    _write_json(output / "dataset_session_plan.json", plan)
    lines = (
        [
            "# Session-based dataset preparation plan",
            "",
            DIAGNOSTIC_LABEL,
            "",
            f"Existing dataset images: {len(dataset_files)}; reviewed calibration images: {len(inventory)}.",
            f"Exact byte-hash matches to the existing dataset: {plan['existing_dataset']['exact_hash_match_count']}.",
            f"Filename-stem matches (may be re-encoded): {plan['existing_dataset']['filename_stem_match_count']}.",
            "",
            "## Recommendation",
            "",
        ]
        + [f"- {item}" for item in plan["recommended_split_plan"]]
        + ["", "## Limitations", ""]
    )
    lines += [f"- {item}" for item in plan["limitations"]] + [
        "",
        "## Capture and annotation checklist",
        "",
    ]
    lines += [f"- {item}" for item in plan["capture_and_annotation_checklist"]]
    (output / "dataset_session_plan.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return plan


def _write_report(
    output: Path,
    summaries: list[dict],
    candidates: dict[str, dict | None],
    dataset_plan: dict,
    baseline_model_path: Path,
    classroom_model_path: Path,
) -> None:
    classroom_current = next(
        (row for row in summaries if row["config_id"] == _config_id("classroom", 0.28, 0.45)), None
    )
    lines = [
        "# Inference calibration diagnostic report",
        "",
        DIAGNOSTIC_LABEL,
        "",
        "## Checkpoints and fixed settings",
        "",
        f"- Baseline checkpoint: `{baseline_model_path}`.",
        f"- Classroom checkpoint: `{classroom_model_path}`.",
        "- Review images: 40 raw images; tracking disabled; imgsz=640; matching IoU=0.50.",
        "- NMS IoU is evaluated by fresh inference for each value; it is not simulated from already-suppressed boxes.",
        "- Source image and checkpoint SHA-256 values are recorded in every raw/configuration artifact.",
        "",
        "## Selected diagnostic candidates",
        "",
        "| Candidate | Model | conf | NMS IoU | TP | FP | FN | Precision | Recall | F1 | Count MAE | Signed bias | Seated recall | Partial recall |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for name, row in candidates.items():
        if row is None:
            lines.append(
                f"| {name} | no configuration met recall >= 0.90 | | | | | | | | | | | | |"
            )
        else:
            lines.append(
                f"| {name} | {row['model_id']} | {row['confidence']:.2f} | {row['nms_iou']:.2f} | "
                f"{row['TP']} | {row['FP']} | {row['FN']} | {row['precision']:.4f} | {row['recall']:.4f} | "
                f"{row['F1']:.4f} | {row['count_MAE']:.4f} | {row['signed_count_bias']:.4f} | "
                f"{row['seated_recall']:.4f} | {row['partial_recall']:.4f} |"
            )
    lines += [
        "",
        "The recall-target candidate is explicitly unavailable when no configuration reaches 0.90 recall.",
        "",
    ]
    if classroom_current:
        lines += [
            "## Current classroom comparison",
            "",
            f"The saved classroom setting is conf={classroom_current['confidence']:.2f}, NMS IoU={classroom_current['nms_iou']:.2f}: "
            f"TP {classroom_current['TP']}, FP {classroom_current['FP']}, FN {classroom_current['FN']}, "
            f"F1 {classroom_current['F1']:.4f}, count MAE {classroom_current['count_MAE']:.4f}.",
            "Per-image regressions against the corresponding saved settings are in `comparison/per_image_regressions.csv`.",
            "",
        ]
    lines += [
        "## Error-overlay review",
        "",
        "The existing classroom overlays were reviewed for frames 0023, 0036, 0102, 0151, and 0035.",
        "",
        "- 0023: a missed rear/partially visible person and loose orange boxes around seated people; the visible false positives are not automatically classified as duplicates.",
        "- 0036: a missed rear seated person plus a very loose foreground box; the count error is consistent with localization mismatch rather than proof of a duplicate.",
        "- 0102: a missed person near the left-center seating area and loose/misaligned boxes near visible people; some boxes are background/scene-adjacent and need human review.",
        "- 0151: a missed person near the rear-right seating area and low-overlap orange boxes; overlapping-looking boxes around foreground people are not a numeric duplicate verdict.",
        "- 0035: the center cluster has loose/misaligned boxes and a missed person; this is a crowded localization case.",
        "",
        "These findings preserve the distinction between background false positives, loose/misplaced boxes, missed seated/partial people, and visually duplicate-like boxes. Numeric duplicate candidates are only IoU-based review leads; zero candidates does not prove that no visually duplicated boxes exist.",
        "",
        "## Recommended next action",
        "",
        "Use the selected rows only to choose a diagnostic operating point for a new independent-session validation run. Do not change production settings from this report. Reserve a genuinely independent capture session before retraining; after that reservation, the reviewed labels can be considered for training data by session, subject to the session/hash/near-duplicate checks in the accompanying plan.",
        "",
        "## Dataset limitation",
        "",
        f"The current review set and existing dataset are tied to capture session `{dataset_plan['review_set']['session']}`. "
        "The current train/validation manifests therefore cannot establish independent test performance.",
        "",
        "Artifacts: `calibration_results.csv`, `calibration_results.json`, `per_image_metrics.csv`, `comparison/`, `overlays/`, and `dataset_session_plan.md`.",
    ]
    (output / "calibration_report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def run_calibration(args: argparse.Namespace) -> int:
    _validate_sweep(tuple(args.confidence), "--confidence")
    _validate_sweep(tuple(args.nms_iou), "--nms-iou")
    if args.imgsz < 1:
        raise ValueError("--imgsz must be positive")
    if not args.input.is_dir() or not args.labels.is_file():
        raise ValueError("--input must be an image directory and --labels must be a file")
    if args.output.resolve() == ROOT.resolve() or args.output.resolve() == args.input.resolve():
        raise ValueError("Calibration output must be a separate directory")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    inventory, label_images, annotations = _load_review_inventory(
        args.input.resolve(), args.labels.resolve()
    )
    models = {
        "baseline": args.baseline_model.resolve(),
        "classroom": args.classroom_model.resolve(),
    }
    for model_id, path in models.items():
        if not path.is_file():
            raise ValueError(f"Missing explicit {model_id} checkpoint: {path}")
    manifest = {
        "schema_version": 1,
        "diagnostic_label": DIAGNOSTIC_LABEL,
        "input": str(args.input.resolve()),
        "labels": str(args.labels.resolve()),
        "labels_sha256": sha256_file(args.labels.resolve()),
        "image_sha256": {item["file_name"]: item["source_sha256"] for item in inventory},
        "confidence": _float_list(tuple(args.confidence)),
        "nms_iou": _float_list(tuple(args.nms_iou)),
        "imgsz": args.imgsz,
        "tracking_used": False,
        "matching_iou": MATCHING_IOU,
        "models": {
            model_id: {"path": str(path), "sha256": sha256_file(path)}
            for model_id, path in models.items()
        },
    }
    manifest_path = output / "calibration_manifest.json"
    if manifest_path.is_file():
        existing = json.loads(manifest_path.read_text(encoding="utf-8"))
        if existing != manifest:
            raise ValueError(
                "Existing calibration output has a different input, model, or sweep; choose a new output directory"
            )
    else:
        _write_json(manifest_path, manifest)

    raw_documents = {}
    summaries = []
    config_documents = []
    for model_id, model_path in models.items():
        model, resolved_path, model_sha256, _ = load_model(str(model_path))
        for nms_iou in args.nms_iou:
            raw_documents[(model_id, nms_iou)] = _run_raw_inference(
                model=model,
                model_id=model_id,
                model_path=resolved_path,
                model_sha256=model_sha256,
                inventory=inventory,
                input_dir=args.input.resolve(),
                output=output,
                nms_iou=nms_iou,
                imgsz=args.imgsz,
            )
        for confidence in args.confidence:
            for nms_iou in args.nms_iou:
                document = _evaluate_config(
                    model_id=model_id,
                    model_path=resolved_path,
                    model_sha256=model_sha256,
                    raw=raw_documents[(model_id, nms_iou)],
                    confidence=confidence,
                    nms_iou=nms_iou,
                    inventory=inventory,
                    label_images=label_images,
                    annotations=annotations,
                    output=output,
                )
                config_documents.append(document)
                summaries.append(document["summary"])
                print(
                    f"EVALUATED {document['config_id']}: F1={document['summary']['F1']:.4f} "
                    f"recall={document['summary']['recall']:.4f} FP={document['summary']['FP']} "
                    f"count_MAE={document['summary']['count_MAE']:.4f}",
                    flush=True,
                )

    summaries.sort(key=lambda row: (row["model_id"], row["confidence"], row["nms_iou"]))
    candidates = _select_candidates(summaries)
    result_document = {
        "status": "completed",
        "diagnostic_label": DIAGNOSTIC_LABEL,
        "settings": {
            "confidence": _float_list(tuple(args.confidence)),
            "nms_iou": _float_list(tuple(args.nms_iou)),
            "inference_min_confidence": MIN_INFERENCE_CONFIDENCE,
            "imgsz": args.imgsz,
            "tracking_used": False,
            "matching_iou": MATCHING_IOU,
            "nms_is_fresh_inference": True,
        },
        "models": manifest["models"],
        "images": inventory,
        "summary": summaries,
        "selected_candidates": candidates,
        "recall_target_met": candidates["recall_at_least_0.90_fewest_FP"] is not None,
        "uncertain_policy": "Uncertain GT excluded from scored GT; predictions overlapping only uncertain GT at IoU >= 0.50 are ignored.",
        "prediction_records": "Each per-configuration JSON contains all 40 frame records, including detections: [] when empty.",
    }
    _write_json(output / "calibration_results.json", result_document)
    _write_csv(output / "calibration_results.csv", _summary_csv_rows(summaries))
    _write_per_image_csv(output / "per_image_metrics.csv", config_documents)

    saved_rows = {}
    for model_id in ("baseline", "classroom"):
        saved_id = _config_id(model_id, 0.28, 0.45)
        saved_rows[saved_id] = next(row for row in summaries if row["config_id"] == saved_id)
    regression_rows = []
    for document in config_documents:
        current = saved_rows[_config_id(document["summary"]["model_id"], 0.28, 0.45)]
        current_document = next(
            item for item in config_documents if item["config_id"] == current["config_id"]
        )
        current_by_file = {frame["file"]: frame["metrics"] for frame in current_document["frames"]}
        for frame in document["frames"]:
            base = current_by_file[frame["file"]]
            metrics = frame["metrics"]
            regression_rows.append(
                {
                    "config_id": document["config_id"],
                    "model_id": document["summary"]["model_id"],
                    "file_name": frame["file"],
                    "source_sha256": frame["source_sha256"],
                    "candidate_FP_minus_saved": metrics["FP"] - base["FP"],
                    "candidate_FN_minus_saved": metrics["FN"] - base["FN"],
                    "candidate_count_error_minus_saved": metrics["absolute_count_error"]
                    - base["absolute_count_error"],
                    "candidate_recall_minus_saved": (
                        (
                            metrics["TP"] / (metrics["TP"] + metrics["FN"])
                            if metrics["TP"] + metrics["FN"]
                            else 0.0
                        )
                        - (
                            base["TP"] / (base["TP"] + base["FN"])
                            if base["TP"] + base["FN"]
                            else 0.0
                        )
                    ),
                }
            )
    _write_csv(output / "comparison" / "per_image_regressions.csv", regression_rows)
    current_classroom = saved_rows[_config_id("classroom", 0.28, 0.45)]
    candidate_rows = []
    for name, row in candidates.items():
        if row is None:
            candidate_rows.append(
                {
                    "candidate": name,
                    "config_id": "none_met_recall_target",
                    "vs_current_classroom_config": current_classroom["config_id"],
                }
            )
            continue
        candidate_rows.append(
            {
                "candidate": name,
                **row,
                "vs_current_classroom_config": current_classroom["config_id"],
                "delta_FP_vs_current_classroom": row["FP"] - current_classroom["FP"],
                "delta_FN_vs_current_classroom": row["FN"] - current_classroom["FN"],
                "delta_F1_vs_current_classroom": row["F1"] - current_classroom["F1"],
                "delta_count_MAE_vs_current_classroom": row["count_MAE"]
                - current_classroom["count_MAE"],
                "delta_recall_vs_current_classroom": row["recall"] - current_classroom["recall"],
                "delta_signed_bias_vs_current_classroom": row["signed_count_bias"]
                - current_classroom["signed_count_bias"],
            }
        )
    _write_csv(output / "comparison" / "candidate_comparison.csv", candidate_rows)
    dataset_plan = _write_dataset_plan(
        output, args.input.resolve(), inventory, args.dataset_root.resolve()
    )
    documents_by_id = {document["config_id"]: document for document in config_documents}
    _write_overlays(
        output=output,
        input_dir=args.input.resolve(),
        documents=documents_by_id,
        label_images=label_images,
        annotations=annotations,
        candidates=candidates,
        inventory=inventory,
    )
    _write_report(
        output, summaries, candidates, dataset_plan, models["baseline"], models["classroom"]
    )
    print(
        json.dumps({"output": str(output), "selected_candidates": candidates}, indent=2), flush=True
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run", help="Run or resume the 70-configuration two-checkpoint sweep")
    run.add_argument("--input", type=Path, required=True)
    run.add_argument("--labels", type=Path, required=True)
    run.add_argument("--output", type=Path, required=True)
    run.add_argument("--baseline-model", type=Path, required=True)
    run.add_argument("--classroom-model", type=Path, required=True)
    run.add_argument("--dataset-root", type=Path, default=ROOT / "dataset")
    run.add_argument("--confidence", type=float, nargs="+", default=DEFAULT_CONFIDENCES)
    run.add_argument("--nms-iou", type=float, nargs="+", default=DEFAULT_NMS_IOUS)
    run.add_argument("--imgsz", type=int, default=640)
    run.set_defaults(function=run_calibration)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.function(args)
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as exc:
        parser.exit(1, f"Calibration diagnostics: {exc}\n")


if __name__ == "__main__":
    raise SystemExit(main())
