"""Offline Pi 5 detector diagnostics, label review export, and evaluation.

This module deliberately has no camera, MQTT, preview-server, or actuator setup.
Ultralytics is imported only when an inference command is executed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
from typing import Any

import cv2
import numpy as np

from .classroom_tracker import ClassroomMotionTracker, TrackedPerson

ROOT = Path(__file__).resolve().parent.parent
IMAGE_EXTENSIONS = {".bmp", ".jpeg", ".jpg", ".png"}
VIDEO_EXTENSIONS = {".avi", ".m4v", ".mkv", ".mov", ".mp4", ".webm"}
MODEL_FALLBACKS = (
    ROOT / "models/classroom_yolo_best.pt",
    ROOT / "yolov8n_classroom.pt",
    ROOT / "runs/train/classroom_person_detector/weights/best.pt",
    ROOT / "models/classroom_yolo_best.onnx",
    ROOT / "runs/train/classroom_person_detector/weights/best.onnx",
    ROOT / "yolov8n.pt",
)


def sha256_file(path: Path) -> str:
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def resolve_model_path(candidate: str = "auto") -> Path:
    """Resolve one model, allowing fallback only for the literal ``auto``."""
    if candidate == "auto":
        for path in MODEL_FALLBACKS:
            if path.is_file():
                return path.resolve()
        raise FileNotFoundError(
            "No model found for --model auto; checked: "
            + ", ".join(str(path) for path in MODEL_FALLBACKS)
        )

    requested = Path(candidate)
    candidates = (
        [requested] if requested.is_absolute() else [Path.cwd() / requested, ROOT / requested]
    )
    for path in candidates:
        if path.is_file():
            return path.resolve()
    raise FileNotFoundError(
        f"Explicit model path does not exist: {candidate}. "
        "Only --model auto permits fallback selection."
    )


def class_names(model: Any) -> dict[str, str]:
    names = getattr(model, "names", None)
    if names is None and getattr(model, "model", None) is not None:
        names = getattr(model.model, "names", None)
    if isinstance(names, dict):
        return {
            str(key): str(value)
            for key, value in sorted(names.items(), key=lambda item: int(item[0]))
        }
    if isinstance(names, (list, tuple)):
        return {str(index): str(value) for index, value in enumerate(names)}
    return {}


def load_model(candidate: str) -> tuple[Any, Path, str, dict[str, str]]:
    path = resolve_model_path(candidate)
    try:
        from ultralytics import YOLO
    except ImportError as exc:
        raise RuntimeError(
            "Ultralytics is required for the Pi 5 YOLO diagnostics; "
            "install the inference environment"
        ) from exc
    model = YOLO(str(path))
    digest = sha256_file(path)
    names = class_names(model)
    print(json.dumps({"model_path": str(path), "sha256": digest, "class_names": names}))
    return model, path, digest, names


def preprocessing_metadata(*, flip_180: bool, source_kind: str) -> dict[str, Any]:
    return {
        "source_kind": source_kind,
        "decoded_color_order": "BGR (cv2.imread/cv2.VideoCapture)",
        "model_source_color_order": (
            "BGR ndarray passed to the same Ultralytics API as live runtime"
        ),
        "orientation": "180-degree flip applied" if flip_180 else "no additional rotation/flip",
        "resize": "Ultralytics imgsz with rect=True; no diagnostic-side resize",
        "coordinates": (
            "xyxy pixel edges in the postprocessed original frame; normalized by frame width/height"
        ),
        "exif": "not applied; cv2 decoding matches the current live/static-image path",
    }


def prepare_live_frame(frame: np.ndarray, *, flip_180: bool) -> np.ndarray:
    if frame is None or frame.ndim != 3 or frame.shape[2] != 3:
        raise ValueError("Expected a nonempty 3-channel BGR frame")
    return cv2.flip(frame, -1) if flip_180 else frame


def _validate_thresholds(conf: float, iou: float, imgsz: int) -> None:
    if not 0 <= conf <= 1 or not math.isfinite(conf):
        raise ValueError("--conf must be finite and in [0,1]")
    if not 0 < iou <= 1 or not math.isfinite(iou):
        raise ValueError("--iou must be finite and in (0,1]")
    if imgsz < 1:
        raise ValueError("--imgsz must be positive")


def detect_frame(
    model: Any, frame: np.ndarray, *, conf: float, iou: float, imgsz: int
) -> list[dict[str, Any]]:
    """Run the live detector call; returned boxes are already model-postprocessed."""
    results = model.predict(
        source=frame,
        conf=conf,
        iou=iou,
        classes=[0],
        imgsz=imgsz,
        rect=True,
        verbose=False,
    )
    first = next(iter(results), None)
    boxes = getattr(first, "boxes", None)
    if boxes is None:
        return []
    height, width = frame.shape[:2]
    detections = []
    for box in boxes:
        class_id = int(box.cls[0].item())
        confidence = float(box.conf[0].item())
        x1, y1, x2, y2 = [float(value) for value in box.xyxy[0].tolist()]
        x1, y1 = max(0.0, min(float(width), x1)), max(0.0, min(float(height), y1))
        x2, y2 = max(0.0, min(float(width), x2)), max(0.0, min(float(height), y2))
        if x2 <= x1 or y2 <= y1:
            continue
        detections.append(
            {
                "class_id": class_id,
                "class_name": "person" if class_id == 0 else str(class_id),
                "confidence": confidence,
                "xyxy": [x1, y1, x2, y2],
                "normalized_xyxy": [x1 / width, y1 / height, x2 / width, y2 / height],
            }
        )
    return detections


def _detection_tuples(
    detections: list[dict[str, Any]],
) -> list[tuple[tuple[float, float, float, float], float]]:
    return [
        (tuple(item["normalized_xyxy"]), float(item["confidence"]))
        for item in detections
        if item["class_id"] == 0
    ]


def _draw_box(
    image: np.ndarray, xyxy: list[float], color: tuple[int, int, int], label: str
) -> None:
    x1, y1, x2, y2 = [round(value) for value in xyxy]
    cv2.rectangle(image, (x1, y1), (x2, y2), color, 2)
    cv2.putText(image, label, (x1, max(16, y1 - 5)), cv2.FONT_HERSHEY_SIMPLEX, 0.48, color, 2)


def _draw_detector(image: np.ndarray, detections: list[dict[str, Any]]) -> None:
    for item in detections:
        _draw_box(
            image,
            item["xyxy"],
            (0, 165, 255),
            f"det {item['confidence']:.3f}",
        )


def _person_box(person: TrackedPerson, size: tuple[int, int]) -> list[float]:
    width, height = size
    x1, y1, x2, y2 = person.bbox
    return [x1 * width, y1 * height, x2 * width, y2 * height]


def _draw_tracks(image: np.ndarray, tracks: list[TrackedPerson]) -> None:
    colors = {"CONFIRMED": (0, 220, 0), "TENTATIVE": (0, 220, 255), "RETAINED": (255, 120, 0)}
    size = (image.shape[1], image.shape[0])
    for person in tracks:
        state = person.lifecycle
        _draw_box(
            image,
            _person_box(person, size),
            colors.get(state, (255, 255, 255)),
            f"track {person.track_id} {state.lower()}",
        )


def _write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n", encoding="utf-8")


def diagnose_images(args: argparse.Namespace) -> int:
    _validate_thresholds(args.conf, args.iou, args.imgsz)
    input_dir = args.input.resolve()
    if not input_dir.is_dir():
        raise ValueError(f"Image input is not a directory: {input_dir}")
    paths = sorted(
        [
            path
            for path in input_dir.iterdir()
            if path.is_file() and path.suffix.lower() in IMAGE_EXTENSIONS
        ],
        key=lambda path: (path.name.casefold(), path.name),
    )
    if not paths:
        raise ValueError(f"No supported images in: {input_dir}")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    annotated_dir = output / "annotated"
    annotated_dir.mkdir(exist_ok=True)
    model, model_path, digest, names = load_model(args.model)
    metadata = {
        "workflow": "detector_only_image_folder",
        "hardware_target": "Raspberry Pi 5 8 GB",
        "camera_used": False,
        "mqtt_used": False,
        "tracking_used": False,
        "model_path": str(model_path),
        "model_sha256": digest,
        "class_names": names,
        "confidence_threshold": args.conf,
        "model_internal_iou": args.iou,
        "imgsz": args.imgsz,
        "detector_output_note": (
            "Ultralytics returned boxes may already have model-internal suppression; "
            "they are not pre-NMS raw predictions."
        ),
        "preprocessing": preprocessing_metadata(flip_180=args.flip_180, source_kind="image_folder"),
    }
    records = []
    errors = []
    for path in paths:
        frame = cv2.imread(str(path), cv2.IMREAD_COLOR)
        if frame is None:
            errors.append({"file": path.name, "error": "unreadable image"})
            continue
        frame = prepare_live_frame(frame, flip_180=args.flip_180)
        detections = detect_frame(model, frame, conf=args.conf, iou=args.iou, imgsz=args.imgsz)
        annotated = frame.copy()
        _draw_detector(annotated, detections)
        cv2.imwrite(str(annotated_dir / path.name), annotated)
        records.append(
            {
                "file": path.name,
                "timestamp_seconds": None,
                "frame_index": None,
                "width": frame.shape[1],
                "height": frame.shape[0],
                "detections": detections,
            }
        )
    metadata.update({"processed_images": len(records), "errors": errors})
    _write_json(output / "inference_metadata.json", metadata)
    _write_json(output / "detections.json", {"metadata": metadata, "frames": records})
    return 2 if errors else 0


def diagnose_video(args: argparse.Namespace) -> int:
    _validate_thresholds(args.conf, args.iou, args.imgsz)
    video_path = args.input.resolve()
    if not video_path.is_file():
        raise ValueError(
            f"Video input must be an existing file; camera sources are not allowed: {video_path}"
        )
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    model, model_path, digest, names = load_model(args.model)
    capture = cv2.VideoCapture(str(video_path))
    if not capture.isOpened():
        raise ValueError(f"Could not open video file: {video_path}")
    fps = float(capture.get(cv2.CAP_PROP_FPS))
    fps = fps if math.isfinite(fps) and fps > 0 else 0.0
    width = int(capture.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(capture.get(cv2.CAP_PROP_FRAME_HEIGHT))
    writer = None
    if args.annotated_video:
        writer = cv2.VideoWriter(
            str(output / "annotated_tracks.mp4"),
            cv2.VideoWriter_fourcc(*"mp4v"),
            fps or 25.0,
            (width, height),
        )
        if not writer.isOpened():
            capture.release()
            raise ValueError("Could not create annotated video output")
    tracker = ClassroomMotionTracker(
        iou_threshold=args.track_iou,
        centroid_distance_thresh=args.centroid_distance,
        max_age_seconds=args.track_max_age,
        confirmation_hits=args.confirm_hits,
        split_y=args.split_y,
        invert_zones=not args.no_invert_zones,
    )
    frames = []
    frame_index = 0
    try:
        while True:
            ok, raw_frame = capture.read()
            if not ok:
                break
            frame = prepare_live_frame(raw_frame, flip_180=args.flip_180)
            timestamp = frame_index / fps if fps else float(frame_index)
            detections = detect_frame(model, frame, conf=args.conf, iou=args.iou, imgsz=args.imgsz)
            tracks = tracker.update(_detection_tuples(detections), now=timestamp)
            counts = tracker.diagnostics()
            annotated = frame.copy()
            _draw_detector(annotated, detections)
            _draw_tracks(annotated, tracks)
            cv2.putText(
                annotated,
                f"t={timestamp:.3f}s det={len(detections)} "
                f"confirmed={counts['observed_confirmed_count']} "
                f"tentative={counts['tentative_track_count']} "
                f"retained={counts['retained_track_count']}",
                (8, 22),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.5,
                (255, 255, 255),
                2,
            )
            if writer is not None:
                writer.write(annotated)
            frames.append(
                {
                    "frame_index": frame_index,
                    "timestamp_seconds": timestamp,
                    "detector_count": len(detections),
                    "detections": detections,
                    "observed_confirmed_count": counts["observed_confirmed_count"],
                    "tentative_track_count": counts["tentative_track_count"],
                    "retained_track_count": counts["retained_track_count"],
                    "tracks": [
                        {
                            "track_id": person.track_id,
                            "lifecycle": person.lifecycle,
                            "observed_this_frame": person.current_frame_observed,
                            "normalized_xyxy": list(person.bbox),
                            "confidence": person.confidence,
                        }
                        for person in tracks
                    ],
                }
            )
            frame_index += 1
    finally:
        capture.release()
        if writer is not None:
            writer.release()
    metadata = {
        "workflow": "detector_and_tracker_video",
        "hardware_target": "Raspberry Pi 5 8 GB",
        "camera_used": False,
        "mqtt_used": False,
        "physical_calibration_used": False,
        "model_path": str(model_path),
        "model_sha256": digest,
        "class_names": names,
        "confidence_threshold": args.conf,
        "model_internal_iou": args.iou,
        "tracker_iou": args.track_iou,
        "confirm_hits": args.confirm_hits,
        "track_max_age_seconds": args.track_max_age,
        "video_fps": fps,
        "detector_output_note": (
            "Ultralytics returned boxes may already have model-internal suppression; "
            "they are not pre-NMS raw predictions."
        ),
        "preprocessing": preprocessing_metadata(flip_180=args.flip_180, source_kind="video_file"),
    }
    _write_json(output / "video_metadata.json", metadata)
    _write_json(output / "video_diagnostics.json", {"metadata": metadata, "frames": frames})
    return 0


def _yolo_label_path(labels: Path, image: Path) -> Path:
    return labels / f"{image.stem}.txt" if labels.is_dir() else image.with_suffix(".txt")


def _read_yolo_labels(path: Path) -> list[list[float]]:
    if not path.is_file():
        return []
    boxes = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        parts = line.split()
        if not parts:
            continue
        if len(parts) != 5:
            raise ValueError(f"{path}:{line_number}: expected class cx cy width height")
        values = [float(value) for value in parts]
        class_id, cx, cy, width, height = values
        if class_id != 0 or not all(math.isfinite(value) for value in values[1:]):
            raise ValueError(f"{path}:{line_number}: invalid person label")
        if not (0 <= cx <= 1 and 0 <= cy <= 1 and 0 < width <= 1 and 0 < height <= 1):
            raise ValueError(f"{path}:{line_number}: YOLO coordinates out of range")
        boxes.append([cx - width / 2, cy - height / 2, cx + width / 2, cy + height / 2])
    return boxes


def _coco_labels(path: Path) -> tuple[dict[str, list[list[float]]], bool]:
    document = json.loads(path.read_text(encoding="utf-8"))
    images = {int(item["id"]): item for item in document.get("images", [])}
    labels: dict[str, list[list[float]]] = {item["file_name"]: [] for item in images.values()}
    for annotation in document.get("annotations", []):
        if annotation.get("category_id") != 1:
            continue
        image = images[int(annotation["image_id"])]
        x, y, width, height = [float(value) for value in annotation["bbox"]]
        labels[image["file_name"]].append(
            [
                x / image["width"],
                y / image["height"],
                (x + width) / image["width"],
                (y + height) / image["height"],
            ]
        )
    reviewed = bool(document.get("info", {}).get("annotation_source") == "human_manual") and all(
        bool(image.get("reviewed")) and bool(str(image.get("reviewed_by", "")).strip())
        for image in images.values()
    )
    return labels, reviewed


def _label_map(labels: Path, images: list[Path]) -> tuple[dict[str, list[list[float]]], bool]:
    if labels.suffix.lower() == ".json":
        return _coco_labels(labels)
    return {
        image.name: _read_yolo_labels(_yolo_label_path(labels, image)) for image in images
    }, False


def export_label_review(args: argparse.Namespace) -> int:
    if not args.input.is_dir():
        raise ValueError(f"Image input is not a directory: {args.input}")
    images = sorted(
        [
            path
            for path in args.input.iterdir()
            if path.is_file() and path.suffix.lower() in IMAGE_EXTENSIONS
        ],
        key=lambda path: (path.name.casefold(), path.name),
    )
    label_map, reviewed = _label_map(args.labels, images)
    output = args.output.resolve()
    annotated_dir = output / "annotated"
    annotated_dir.mkdir(parents=True, exist_ok=True)
    manifest = []
    for image_path in images:
        image = cv2.imread(str(image_path), cv2.IMREAD_COLOR)
        if image is None:
            continue
        boxes = label_map.get(image_path.name, [])
        for box in boxes:
            _draw_box(
                image,
                [
                    box[0] * image.shape[1],
                    box[1] * image.shape[0],
                    box[2] * image.shape[1],
                    box[3] * image.shape[0],
                ],
                (255, 0, 255),
                "UNREVIEWED PSEUDO-LABEL" if not reviewed else "REVIEWED LABEL",
            )
        cv2.imwrite(str(annotated_dir / image_path.name), image)
        manifest.append({"file": image_path.name, "label_count": len(boxes), "reviewed": reviewed})
    _write_json(
        output / "label_review_manifest.json",
        {
            "workflow": "label_review_export",
            "annotation_files_modified": False,
            "review_status": "reviewed" if reviewed else "unreviewed_pseudo_labels",
            "note": (
                "Automatically generated labels are pseudo-labels until a human reviews them. "
                "This export never edits annotations."
            ),
            "images": manifest,
        },
    )
    return 0


def _box_iou(a: list[float], b: list[float]) -> float:
    x1, y1 = max(a[0], b[0]), max(a[1], b[1])
    x2, y2 = min(a[2], b[2]), min(a[3], b[3])
    intersection = max(0.0, x2 - x1) * max(0.0, y2 - y1)
    area_a = max(0.0, a[2] - a[0]) * max(0.0, a[3] - a[1])
    area_b = max(0.0, b[2] - b[0]) * max(0.0, b[3] - b[1])
    union = area_a + area_b - intersection
    return intersection / union if union else 0.0


def evaluate_predictions(args: argparse.Namespace) -> int:
    if not args.predictions.is_file() or not args.labels.is_file():
        raise ValueError("--predictions and --labels must be files")
    document = json.loads(args.predictions.read_text(encoding="utf-8"))
    labels, reviewed = _coco_labels(args.labels)
    if not reviewed:
        raise ValueError(
            "Evaluation requires every label image to be human-reviewed with a reviewer"
        )
    frames = {frame["file"]: frame for frame in document.get("frames", [])}
    tp = fp = fn = duplicate = total_predictions = absolute_count_error = image_count = 0
    for image_name, ground_truth in labels.items():
        predictions = [
            item
            for item in frames.get(image_name, {}).get("detections", [])
            if item.get("class_id") == 0
        ]
        predictions.sort(key=lambda item: float(item["confidence"]), reverse=True)
        matched: set[int] = set()
        for prediction in predictions:
            total_predictions += 1
            best = max(
                (
                    (_box_iou(prediction["normalized_xyxy"], box), index)
                    for index, box in enumerate(ground_truth)
                    if index not in matched
                ),
                default=(0.0, -1),
            )
            if best[0] >= args.match_iou:
                tp += 1
                matched.add(best[1])
            else:
                fp += 1
                if any(
                    _box_iou(prediction["normalized_xyxy"], box) >= args.match_iou
                    for box in ground_truth
                ):
                    duplicate += 1
        fn += len(ground_truth) - len(matched)
        absolute_count_error += abs(len(predictions) - len(ground_truth))
        image_count += 1
    precision = tp / (tp + fp) if tp + fp else 0.0
    recall = tp / (tp + fn) if tp + fn else 0.0
    report = {
        "human_review_required": True,
        "images_evaluated": image_count,
        "matching_iou": args.match_iou,
        "matching_rule": (
            "Per image, sort predictions by descending confidence and greedily match each "
            "to at most one unmatched person label at IoU >= matching_iou."
        ),
        "duplicate_rule": (
            "An unmatched prediction whose IoU with any ground-truth person is >= "
            "matching_iou is counted as a duplicate; duplicate_rate is "
            "duplicates / all predictions."
        ),
        "count_error_rule": (
            "Mean absolute error of predicted person count minus reviewed person count, per image."
        ),
        "true_positive": tp,
        "false_positive": fp,
        "false_negative": fn,
        "duplicate_predictions": duplicate,
        "precision": precision,
        "recall": recall,
        "duplicate_rate": duplicate / total_predictions if total_predictions else 0.0,
        "mean_absolute_count_error": absolute_count_error / image_count if image_count else 0.0,
        "warning": "These offline image metrics do not establish classroom reliability.",
    }
    _write_json(args.output, report)
    print(json.dumps(report, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    def detector_args(command: argparse.ArgumentParser, *, flip_default: bool) -> None:
        command.add_argument(
            "--model", default="auto", help="YOLO model path, or auto for reviewed fallback order"
        )
        command.add_argument("--conf", type=float, default=0.28)
        command.add_argument(
            "--iou", type=float, default=0.45, help="Ultralytics model-internal suppression IoU"
        )
        command.add_argument("--imgsz", type=int, default=640)
        flip = command.add_mutually_exclusive_group()
        flip.add_argument(
            "--flip-180",
            dest="flip_180",
            action="store_true",
            help="Apply the live ceiling-mount 180-degree orientation",
        )
        flip.add_argument(
            "--no-flip",
            dest="flip_180",
            action="store_false",
            help="Do not apply the live ceiling-mount orientation",
        )
        command.set_defaults(flip_180=flip_default)

    images = sub.add_parser("images", help="Detector-only image-folder diagnostics")
    images.add_argument("--input", type=Path, required=True)
    images.add_argument("--output", type=Path, required=True)
    detector_args(images, flip_default=False)
    images.set_defaults(function=diagnose_images)

    video = sub.add_parser("video", help="Offline video detector/tracker lifecycle diagnostics")
    video.add_argument(
        "--input", type=Path, required=True, help="Existing video file; camera devices are rejected"
    )
    video.add_argument("--output", type=Path, required=True)
    detector_args(video, flip_default=True)
    video.add_argument("--track-iou", type=float, default=0.18)
    video.add_argument("--confirm-hits", type=int, default=2)
    video.add_argument("--track-max-age", type=float, default=1.5)
    video.add_argument("--centroid-distance", type=float, default=0.06)
    video.add_argument("--split-y", type=float, default=0.48)
    video.add_argument("--no-invert-zones", action="store_true")
    video.add_argument("--annotated-video", action="store_true")
    video.set_defaults(function=diagnose_video)

    review = sub.add_parser(
        "review-labels", help="Export existing labels over clean images without editing labels"
    )
    review.add_argument("--input", type=Path, required=True)
    review.add_argument(
        "--labels", type=Path, required=True, help="YOLO label directory/sidecars or COCO JSON"
    )
    review.add_argument("--output", type=Path, required=True)
    review.set_defaults(function=export_label_review)

    evaluate = sub.add_parser(
        "evaluate", help="Evaluate predictions against fully human-reviewed COCO labels"
    )
    evaluate.add_argument(
        "--predictions", type=Path, required=True, help="detections.json from images"
    )
    evaluate.add_argument(
        "--labels", type=Path, required=True, help="COCO labels with reviewed=true and reviewed_by"
    )
    evaluate.add_argument("--output", type=Path, required=True)
    evaluate.add_argument("--match-iou", type=float, default=0.5)
    evaluate.set_defaults(function=evaluate_predictions)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if getattr(args, "match_iou", 0.5) <= 0 or getattr(args, "match_iou", 0.5) > 1:
        parser.error("--match-iou must be in (0,1]")
    try:
        return args.function(args)
    except (OSError, ValueError, RuntimeError) as exc:
        parser.exit(1, f"Offline diagnostics: {exc}\n")


if __name__ == "__main__":
    raise SystemExit(main())
