"""Offline real-model image inference and auditable prediction artifacts; no MQTT/camera."""

from __future__ import annotations

import csv
import hashlib
import json
import logging
import platform
import sys
from datetime import UTC, datetime
from pathlib import Path

import numpy as np
from PIL import __version__ as pillow_version

from .config import AppConfig
from .detector import create_detector
from .images import (
    ImageFolder,
    UnreadableImageError,
    annotate_image,
    detection_record,
    load_rgb_image,
)
from .zones import ZoneMap

LOG = logging.getLogger(__name__)
CSV_FIELDS = [
    "image_filename",
    "detection_index",
    "class_name",
    "class_id",
    "confidence",
    "xmin",
    "ymin",
    "xmax",
    "ymax",
    "center_x",
    "center_y",
    "xmin_normalized",
    "ymin_normalized",
    "xmax_normalized",
    "ymax_normalized",
    "center_x_normalized",
    "center_y_normalized",
]
COORDINATES = {
    "xmin_ymin_xmax_ymax_center_x_center_y": (
        "continuous pixels; origin top-left; x in [0,width], y in [0,height]"
    ),
    "normalized_suffix": "normalized to [0,1] in the same image",
    "image_frame": "full source resolution after EXIF orientation correction, before resize",
    "box_order_from_model": "ymin,xmin,ymax,xmax",
    "detection_index": "1-based within each image, filtered model output order",
}


def _write_json(path: Path, data: dict) -> None:
    temporary = path.with_suffix(path.suffix + ".part")
    temporary.write_text(json.dumps(data, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    temporary.replace(path)


def _summary(images: list[dict], discovered: int, status: str) -> dict:
    successful = [image for image in images if image["status"] == "processed"]
    failed = [image for image in images if image["status"] != "processed"]
    return {
        "schema_version": 1,
        "status": status,
        "result_type": "model_predictions",
        "ground_truth_available": False,
        "accuracy_evaluated": False,
        "images_discovered": discovered,
        "images_processed": len(successful),
        "images_failed": len(failed),
        "images_not_attempted": discovered - len(images),
        "images_with_person_detections": sum(bool(image["detections"]) for image in successful),
        "total_person_detections": sum(len(image["detections"]) for image in successful),
        "image_statuses": [
            {key: image[key] for key in ("image_filename", "status", "error")} for image in images
        ],
    }


def _write_reports(output: Path, images: list[dict], metadata: dict, status: str) -> dict:
    summary = _summary(images, metadata["images_discovered"], status)
    csv_path = output / "detections.csv"
    temporary = csv_path.with_suffix(".csv.part")
    with temporary.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=CSV_FIELDS)
        writer.writeheader()
        for image in images:
            if image["status"] == "processed":
                writer.writerows(image["detections"])
    temporary.replace(csv_path)
    _write_json(
        output / "detections.json",
        {
            "schema_version": 1,
            "result_type": "model_predictions",
            "ground_truth_available": False,
            "coordinate_conventions": COORDINATES,
            "images": images,
        },
    )
    metadata["status"] = status
    metadata["processing"] = {k: v for k, v in summary.items() if k != "image_statuses"}
    metadata["updated_at_utc"] = datetime.now(UTC).isoformat()
    _write_json(output / "summary.json", summary)
    _write_json(output / "inference_metadata.json", metadata)
    return summary


def infer_images(
    config: AppConfig,
    input_folder: Path,
    output_folder: Path,
    *,
    backend: str = "auto",
    overlay_zones: bool = False,
) -> dict:
    """Allocate once, infer each image once, retain errors, and stop on model/output faults."""
    sources = ImageFolder(input_folder.resolve()).discover()
    output = output_folder.resolve()
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        raise ValueError(
            f"Output must be a new or empty directory (existing results preserved): {output}"
        )
    zones = ZoneMap.load(config.zones_path) if overlay_zones else None
    output.mkdir(parents=True, exist_ok=True)
    annotated = output / "annotated"
    annotated.mkdir()
    warnings = [
        "Model predictions only; no ground truth, accuracy assessment or performance benchmark.",
        "At most the allocated SSD detection capacity can be returned per full image.",
    ]
    if overlay_zones:
        warnings.append(
            "Zone overlay is UNCALIBRATED for these images; no occupancy decisions are made."
        )
    metadata = {
        "schema_version": 1,
        "status": "initializing",
        "mode": "offline_image_folder",
        "model": {
            "filename": config.detector.model_path.name,
            "path": str(config.detector.model_path),
            "expected_sha256": config.detector.sha256,
        },
        "software": {
            "python_version": platform.python_version(),
            "python_executable": sys.executable,
            "platform": platform.platform(),
            "numpy_version": np.__version__,
            "pillow_version": pillow_version,
        },
        "requested_backend": backend,
        "input_folder": str(input_folder.resolve()),
        "output_folder": str(output),
        "images_discovered": len(sources),
        "discovery": (
            "nonrecursive; .jpg/.jpeg/.png case-insensitive; sorted by (casefold(name),name)"
        ),
        "source_filenames": [path.name for path in sources],
        "coordinate_conventions": COORDINATES,
        "person_class_id": config.detector.person_class_id,
        "confidence_threshold": config.detector.confidence_threshold,
        "preprocessing": {
            "exif_transpose": True,
            "color": "RGB",
            "resize": "bilinear stretch",
            "input_encoding": config.detector.input_encoding,
            "normalization_applied": config.detector.input_encoding == "normalized_real",
            "configured_mean": config.detector.input_mean,
            "configured_std": config.detector.input_std,
        },
        "zone_overlay": {
            "enabled": overlay_zones,
            "label": "UNCALIBRATED" if overlay_zones else None,
        },
        "mqtt_used": False,
        "camera_used": False,
        "weights_modified": False,
        "warnings": warnings,
        "error": None,
    }
    images: list[dict] = []
    detector = None
    stage = "model_verification_and_allocation"
    _write_reports(output, images, metadata, "initializing")
    try:
        with config.detector.model_path.open("rb") as handle:
            metadata["model"]["sha256"] = hashlib.file_digest(handle, "sha256").hexdigest()
        detector = create_detector(config.detector, backend=backend)
        metadata["runtime"] = detector.runtime_info
        metadata["allocated_tensors"] = detector.allocated_metadata()
        metadata["preprocessing"]["resize_target_width_height"] = [
            detector.input_width,
            detector.input_height,
        ]
        _write_reports(output, images, metadata, "processing")
        for source in sources:
            record = {
                "image_filename": source.name,
                "status": "pending",
                "error": None,
                "detections": [],
                "annotated_image": None,
            }
            stage = f"decode: {source.name}"
            try:
                loaded = load_rgb_image(source)
            except UnreadableImageError as exc:
                record.update(status="unreadable", error=str(exc))
                images.append(record)
                LOG.warning("Skipping unreadable image: %s", exc)
                _write_reports(output, images, metadata, "processing")
                continue
            record.update(
                width=loaded.image.width,
                height=loaded.image.height,
                encoded_width=loaded.encoded_size[0],
                encoded_height=loaded.encoded_size[1],
                exif_orientation=loaded.exif_orientation,
            )
            with source.open("rb") as handle:
                record["source_sha256"] = hashlib.file_digest(handle, "sha256").hexdigest()
            stage = f"inference: {source.name}"
            try:
                if getattr(zones, "schema_version", None) == 2:
                    # A geometry preview is meaningful only for its exact reference photo.
                    zones.verify_reference(source)
                detections = detector.detect(loaded.rgb)
                rows = [
                    detection_record(source.name, i, detection, loaded.image.size)
                    for i, detection in enumerate(detections, start=1)
                ]
                stage = f"annotation: {source.name}"
                destination = annotated / f"{source.name}.annotated.jpg"
                annotate_image(loaded.image, rows, zones).save(
                    destination, format="JPEG", quality=90
                )
            except Exception as exc:
                record.update(status="failed", error=f"{type(exc).__name__}: {exc}")
                images.append(record)
                raise
            record.update(
                status="processed",
                detections=rows,
                annotated_image=destination.relative_to(output).as_posix(),
            )
            images.append(record)
            metadata["allocated_tensors"] = detector.allocated_metadata()
            LOG.info("%s: %d person detections", source.name, len(rows))
            _write_reports(output, images, metadata, "processing")
        return _write_reports(
            output,
            images,
            metadata,
            "completed_with_errors"
            if any(i["status"] != "processed" for i in images)
            else "completed",
        )
    except Exception as exc:
        metadata["error"] = {"stage": stage, "type": type(exc).__name__, "message": str(exc)}
        if detector is not None:
            metadata["allocated_tensors"] = detector.allocated_metadata()
        _write_reports(output, images, metadata, "failed")
        raise RuntimeError(
            f"Offline inference failed at {stage}: {type(exc).__name__}: {exc}"
        ) from exc
