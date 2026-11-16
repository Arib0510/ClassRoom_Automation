import json
from argparse import Namespace
from pathlib import Path

import cv2
import numpy as np
import pytest

from src.offline_diagnostics import (
    _read_yolo_labels,
    evaluate_predictions,
    export_label_review,
    prepare_live_frame,
    preprocessing_metadata,
    resolve_model_path,
)


def test_only_auto_allows_model_fallback_and_explicit_missing_fails(tmp_path):
    with pytest.raises(FileNotFoundError, match="Only --model auto"):
        resolve_model_path(str(tmp_path / "missing.pt"))
    assert resolve_model_path("auto").is_file()


def test_live_frame_orientation_is_explicit_and_preserves_bgr_values():
    frame = np.array([[[1, 2, 3], [4, 5, 6]]], dtype=np.uint8)
    np.testing.assert_array_equal(prepare_live_frame(frame, flip_180=False), frame)
    np.testing.assert_array_equal(
        prepare_live_frame(frame, flip_180=True), np.array([[[4, 5, 6], [1, 2, 3]]], dtype=np.uint8)
    )
    metadata = preprocessing_metadata(flip_180=True, source_kind="video_file")
    assert metadata["decoded_color_order"].startswith("BGR")
    assert "Ultralytics imgsz" in metadata["resize"]
    assert "not applied" in metadata["exif"]


def test_yolo_labels_are_read_without_editing_source(tmp_path):
    labels = tmp_path / "person.txt"
    labels.write_text("0 0.5 0.5 0.2 0.4\n", encoding="utf-8")
    before = labels.read_bytes()
    assert _read_yolo_labels(labels) == [[0.4, 0.3, 0.6, 0.7]]
    assert labels.read_bytes() == before


def test_label_review_export_marks_yolo_labels_as_unreviewed_pseudo_labels(tmp_path):
    images = tmp_path / "images"
    labels = tmp_path / "labels"
    output = tmp_path / "review"
    images.mkdir()
    labels.mkdir()
    cv2.imwrite(str(images / "frame.jpg"), np.full((20, 30, 3), 255, dtype=np.uint8))
    label_path = labels / "frame.txt"
    label_path.write_text("0 0.5 0.5 0.2 0.4\n", encoding="utf-8")
    before = label_path.read_bytes()

    result = export_label_review(Namespace(input=images, labels=labels, output=output))

    assert result == 0
    manifest = json.loads((output / "label_review_manifest.json").read_text(encoding="utf-8"))
    assert manifest["review_status"] == "unreviewed_pseudo_labels"
    assert manifest["annotation_files_modified"] is False
    assert label_path.read_bytes() == before
    assert (output / "annotated/frame.jpg").is_file()


def _reviewed_labels(path: Path):
    path.write_text(
        json.dumps(
            {
                "info": {"annotation_source": "human_manual"},
                "images": [
                    {
                        "id": 1,
                        "file_name": "frame.jpg",
                        "width": 100,
                        "height": 100,
                        "reviewed": True,
                        "reviewed_by": "tester",
                    }
                ],
                "annotations": [
                    {"id": 1, "image_id": 1, "category_id": 1, "bbox": [10, 10, 20, 40]}
                ],
            }
        ),
        encoding="utf-8",
    )


def test_evaluation_reports_greedy_metrics_and_requires_human_review(tmp_path):
    labels = tmp_path / "labels.json"
    _reviewed_labels(labels)
    predictions = tmp_path / "detections.json"
    predictions.write_text(
        json.dumps(
            {
                "frames": [
                    {
                        "file": "frame.jpg",
                        "detections": [
                            {
                                "class_id": 0,
                                "confidence": 0.9,
                                "normalized_xyxy": [0.1, 0.1, 0.3, 0.5],
                            },
                            {
                                "class_id": 0,
                                "confidence": 0.2,
                                "normalized_xyxy": [0.1, 0.1, 0.3, 0.5],
                            },
                        ],
                    }
                ]
            }
        ),
        encoding="utf-8",
    )
    report_path = tmp_path / "report.json"

    assert (
        evaluate_predictions(
            Namespace(predictions=predictions, labels=labels, output=report_path, match_iou=0.5)
        )
        == 0
    )
    report = json.loads(report_path.read_text(encoding="utf-8"))
    assert report["true_positive"] == 1
    assert report["false_positive"] == 1
    assert report["false_negative"] == 0
    assert report["duplicate_predictions"] == 1
    assert report["precision"] == pytest.approx(0.5)
    assert report["recall"] == pytest.approx(1.0)
    assert report["duplicate_rate"] == pytest.approx(0.5)
    assert report["mean_absolute_count_error"] == pytest.approx(1.0)
