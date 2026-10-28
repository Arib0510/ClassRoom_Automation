import copy
import json

import pytest
from PIL import Image

from src.annotate_persons import main as annotate_main
from src.crops import MODES, CropPrediction, make_crops
from src.detector import Detection
from src.person_labels import match_image, new_labels, validate_labels
from src.phase3_diagnostics import (
    label_output_review,
    main,
    metric_totals,
    prediction_row,
    write_comparisons,
)


@pytest.fixture
def dataset(tmp_path):
    folder = tmp_path / "input"
    folder.mkdir()
    Image.new("RGB", (100, 80), "gray").save(folder / "test.jpg")
    return folder, new_labels(folder)


def label(aid=1, uncertain=False, box=None):
    return {
        "id": aid,
        "image_id": 1,
        "category_id": 1,
        "iscrowd": 0,
        "bbox": box or [10, 8, 30, 24],
        "attributes": {"uncertain": uncertain, "partial": True, "seated": True},
    }


def test_annotation_initialization_has_no_predictions_or_implied_empty_ground_truth(
    dataset, tmp_path
):
    folder, labels = dataset
    assert labels["annotations"] == []
    assert not validate_labels(labels, labels["images"])
    path = tmp_path / "labels.json"
    args = ["--input", str(folder), "--labels", str(path), "--init-only"]
    assert annotate_main(args) == 0
    saved = json.loads(path.read_text())
    saved["annotations"] = [label()]
    path.write_text(json.dumps(saved))
    assert annotate_main(args) == 0
    assert json.loads(path.read_text())["annotations"] == saved["annotations"]


@pytest.mark.parametrize(
    "fault",
    ["hash", "size", "category", "duplicate_id", "outside", "nan", "flags", "reviewer", "source"],
)
def test_labels_fail_closed_on_inconsistent_input(dataset, fault):
    _, labels = dataset
    expected = copy.deepcopy(labels["images"])
    labels["annotations"] = [label()]
    if fault == "hash":
        labels["images"][0]["source_sha256"] = "wrong"
    elif fault == "size":
        labels["images"][0]["width"] = 99
    elif fault == "category":
        labels["annotations"][0]["category_id"] = 0  # Model class is NOT COCO label ID.
    elif fault == "duplicate_id":
        labels["annotations"].append(label())
    elif fault == "outside":
        labels["annotations"][0]["bbox"] = [90, 0, 20, 10]
    elif fault == "nan":
        labels["annotations"][0]["bbox"][0] = float("nan")
    elif fault == "flags":
        del labels["annotations"][0]["attributes"]["uncertain"]
    elif fault == "reviewer":
        labels["images"][0]["reviewed"] = True
    else:
        labels["info"]["annotation_source"] = "model_predictions"
    with pytest.raises(ValueError):
        validate_labels(labels, expected)


def test_matching_duplicates_uncertainty_partial_seated_and_false_negatives(dataset):
    _, labels = dataset
    image = labels["images"][0]
    crop = make_crops((100, 80))[0]

    def row(box, score):
        return prediction_row(CropPrediction(Detection(box, score, 0), crop, box), "test.jpg", 1)

    rows = [
        row((0.1, 0.1, 0.4, 0.4), 0.8),
        row((0.1, 0.1, 0.4, 0.4), 0.7),
        row((0.5, 0.5, 0.9, 0.9), 0.6),
    ]
    annotations = [
        label(),
        label(2, uncertain=True, box=[50, 40, 40, 32]),
        label(3, box=[0, 40, 10, 16]),
    ]
    result = match_image(rows, annotations, image, 0.5)
    assert result["true_positives"] == 1
    assert result["false_positives"] == 1  # Duplicate cannot match a second person.
    assert result["false_negatives"] == 1
    assert result["false_negative_annotation_ids"] == [3]
    assert result["uncertain_ignored_prediction_indices"] == [2]
    assert result["partial_actual"] == result["partial_seated_actual"] == 2
    totals = metric_totals([result])
    assert totals["precision"] == totals["person_recall"] == 0.5
    assert totals["partial_seated_recall"] == 0.5


def test_matching_iou_is_applied_not_just_centers(dataset):
    _, labels = dataset
    image = labels["images"][0]
    crop = make_crops((100, 80))[0]
    box = (0.1, 0.1, 0.4, 0.7)  # IoU 0.5 with visible-person label.
    row = prediction_row(CropPrediction(Detection(box, 0.9, 0), crop, box), "test.jpg", 1)
    assert match_image([row], [label()], image, 0.49)["true_positives"] == 1
    assert match_image([row], [label()], image, 0.51)["true_positives"] == 0


def cache_for(labels):
    images = copy.deepcopy(labels["images"])
    for image in images:
        image["modes"] = {mode: {"person_outputs": []} for mode in MODES}
    return {
        "schema_version": 1,
        "status": "completed",
        "images": images,
        "settings": {"nms_iou": 0.5, "matching_iou": 0.5},
    }


def test_raw_label_review_distinguishes_low_scores_from_absent_boxes(dataset):
    _, labels = dataset
    labels["annotations"] = [label()]
    cache = cache_for(labels)
    assert label_output_review(cache, labels)["persons"] is None
    labels["images"][0].update(reviewed=True, reviewed_by="Synthetic test fixture")
    crop = make_crops((100, 80))[0]
    for mode, score in zip(MODES[:3], (0.05, 0.4, 0.6), strict=True):
        box = (0.1, 0.1, 0.4, 0.4)
        row = prediction_row(CropPrediction(Detection(box, score, 0), crop, box), "test.jpg", 1)
        cache["images"][0]["modes"][mode]["person_outputs"] = [row]
    modes = label_output_review(cache, labels)["persons"][0]["modes"]
    assert modes["full"]["status"] == "localized_only_below_0.10"
    assert modes["roi"]["status"] == "localized_below_0.55"
    assert modes["left_right"]["status"] == "localized_at_or_above_0.55"
    assert modes["overlap"]["status"] == "no_returned_person_box_at_matching_iou"


def test_reports_do_not_publish_metrics_until_all_images_human_reviewed(dataset, tmp_path):
    folder, labels = dataset
    labels["annotations"] = [label()]
    output = tmp_path / "reports"
    (output / "ground_truth").mkdir(parents=True)
    cache = cache_for(labels)
    summary = write_comparisons(cache, labels, folder, output)
    assert not summary["accuracy_evaluated"]
    assert summary["modes"]["full"]["0.10"]["metrics"] is None
    report = json.loads((output / "threshold_comparisons/full/threshold_0.10.json").read_text())
    assert report["images"][0]["metrics"] is None
    assert (output / "false_negative_review/pending/test.jpg.jpg").is_file()
    labels["images"][0].update(reviewed=True, reviewed_by="Test human (synthetic fixture)")
    reviewed_output = tmp_path / "reviewed"
    (reviewed_output / "ground_truth").mkdir(parents=True)
    summary = write_comparisons(cache, labels, folder, reviewed_output)
    assert summary["accuracy_evaluated"]
    assert summary["modes"]["full"]["0.10"]["metrics"]["false_negatives"] == 1
    assert summary["modes"]["full"]["0.10"]["metrics"]["person_recall"] == 0
    assert (reviewed_output / "false_negative_review/full/0.10/test.jpg.jpg").is_file()


def test_cached_evaluation_needs_no_runtime_and_preserves_old_results(
    dataset, tmp_path, monkeypatch
):
    folder, labels = dataset

    def forbidden(*args, **kwargs):
        raise AssertionError("Evaluation must not create a runtime")

    monkeypatch.setattr("src.phase3_diagnostics.create_detector", forbidden)
    cache = tmp_path / "cache.json"
    cache.write_text(json.dumps(cache_for(labels)))
    path = tmp_path / "labels.json"
    path.write_text(json.dumps(labels))
    output = tmp_path / "evaluate"
    args = [
        "evaluate",
        "--input",
        str(folder),
        "--output",
        str(output),
        "--labels",
        str(path),
        "--predictions",
        str(cache),
    ]
    assert main(args) == 0
    summary = (output / "summary.json").read_bytes()
    with pytest.raises(SystemExit) as error:
        main(args)
    assert error.value.code == 1
    assert (output / "summary.json").read_bytes() == summary
