import hashlib
from pathlib import Path

import cv2
import numpy as np
import pytest

from src.calibration_diagnostics import _evaluate_config, verify_coordinate_conversion


def _image_record(tmp_path: Path, name: str, index: int) -> dict:
    path = tmp_path / name
    cv2.imwrite(str(path), np.zeros((100, 100, 3), dtype=np.uint8))
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    return {
        "id": index,
        "file_name": name,
        "width": 100,
        "height": 100,
        "source_sha256": digest,
        "reviewed": True,
        "reviewed_by": "test",
    }


def _person_annotation(annotation_id: int, image_id: int) -> dict:
    return {
        "id": annotation_id,
        "image_id": image_id,
        "category_id": 1,
        "iscrowd": 0,
        "bbox": [20, 20, 40, 40],
        "attributes": {"uncertain": False, "partial": True, "seated": True},
    }


def test_coordinate_conversion_is_checked_in_pixel_and_normalized_space():
    verify_coordinate_conversion(
        [
            {
                "xyxy": [10.0, 20.0, 60.0, 80.0],
                "normalized_xyxy": [0.1, 0.2, 0.6, 0.8],
            }
        ],
        100,
        100,
    )
    with pytest.raises(ValueError, match="round-trip"):
        verify_coordinate_conversion(
            [{"xyxy": [10.0, 20.0, 60.0, 80.0], "normalized_xyxy": [0.2, 0.2, 0.6, 0.8]}],
            100,
            100,
        )


def test_calibration_evaluation_keeps_empty_records_and_duplicate_candidates(tmp_path):
    first = _image_record(tmp_path, "frame-0001.png", 1)
    second = _image_record(tmp_path, "frame-0002.png", 2)
    inventory = [first, second]
    label_images = {first["file_name"]: first, second["file_name"]: second}
    annotations = {
        first["file_name"]: [_person_annotation(1, 1)],
        second["file_name"]: [],
    }
    raw = {
        "metadata": {"imgsz": 640},
        "frames": [
            {
                "file": first["file_name"],
                "source_sha256": first["source_sha256"],
                "detections": [
                    {
                        "class_id": 0,
                        "confidence": 0.9,
                        "xyxy": [20.0, 20.0, 60.0, 60.0],
                        "normalized_xyxy": [0.2, 0.2, 0.6, 0.6],
                    },
                    {
                        "class_id": 0,
                        "confidence": 0.8,
                        "xyxy": [20.0, 20.0, 60.0, 60.0],
                        "normalized_xyxy": [0.2, 0.2, 0.6, 0.6],
                    },
                ],
            },
            {
                "file": second["file_name"],
                "source_sha256": second["source_sha256"],
                "detections": [],
            },
        ],
    }
    result = _evaluate_config(
        model_id="test",
        model_path=tmp_path / "model.pt",
        model_sha256="model-hash",
        raw=raw,
        confidence=0.2,
        nms_iou=0.45,
        inventory=inventory,
        label_images=label_images,
        annotations=annotations,
        output=tmp_path / "output",
    )
    assert result["summary"]["TP"] == 1
    assert result["summary"]["FP"] == 1
    assert result["summary"]["FN"] == 0
    assert result["summary"]["duplicate_candidates"] == 1
    assert result["summary"]["seated_recall"] == pytest.approx(1.0)
    assert result["summary"]["partial_recall"] == pytest.approx(1.0)
    assert result["frames"][1]["detections"] == []
