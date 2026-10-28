"""Synthetic contract tests, explicitly separate from genuine model execution."""

import copy
import json
import socket
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

from src.detector import ModelContractError
from src.experimental_detector import (
    YOLOv5n,
    person_candidates,
    person_nms,
    prediction_records,
    probability,
    reverse_letterbox,
    verify_artifacts,
)
from src.person_labels import new_labels
from src.phase4_comparison import (
    annotation_inventory,
    baseline_verification,
    evaluate_configuration,
)
from src.phase4_zones import (
    UNKNOWN,
    binary_zone_metrics,
    main,
    new_zone_labels,
    validate_zone_labels,
)
from src.zones import ZONE_IDS


@pytest.fixture
def labels(tmp_path):
    Image.new("RGB", (200, 100)).save(tmp_path / "a.jpg")
    document = new_labels(tmp_path)
    document["images"][0].update(reviewed=True, reviewed_by="human")
    document["annotations"] = [
        {
            "id": 1,
            "image_id": 1,
            "category_id": 1,
            "bbox": [20, 10, 40, 40],
            "iscrowd": 0,
            "attributes": {"seated": True, "partial": False, "uncertain": False},
        }
    ]
    return document


@pytest.fixture
def metadata():
    return {
        "original_size_wh": [200, 100],
        "input_size_wh": [320, 320],
        "ratio_xy": [1.6, 1.6],
        "pad_xy": [0, 80],
    }


def test_decoded_contract_best_class_filter_and_objectness_product():
    raw = np.zeros((1, 3, 85), dtype=np.float32)
    raw[0, :, :5] = [50, 60, 20, 30, 0.5]
    raw[0, :, 5] = [0.8, 0.6, 0.1]
    raw[0, 1, 6] = 0.9  # Non-person is best even though person exceeds cutoff.
    rows = person_candidates(raw, 0.10, 0)
    assert rows.shape == (1, 6)
    assert rows[0] == pytest.approx([40, 45, 60, 75, 0.4, 0])


@pytest.mark.parametrize("value", [-0.1, 1.1, float("nan"), float("inf"), True])
def test_bad_threshold(value):
    with pytest.raises(ValueError):
        probability(value)


def test_threshold_boundary_is_inclusive():
    raw = np.zeros((1, 1, 85))
    raw[0, 0, :6] = [50, 50, 10, 10, 1, 0.10]
    assert len(person_candidates(raw, 0.10, 0)) == 1
    assert len(person_candidates(raw, 0.10001, 0)) == 0
    assert len(person_candidates(raw, 1, 0)) == 0


@pytest.mark.parametrize("fault", ["shape", "nan", "score", "negative_width", "class"])
def test_malformed_yolo_outputs(fault):
    raw = np.zeros((1, 1, 85))
    person = 0
    if fault == "shape":
        raw = np.zeros((1, 1, 84))
    if fault == "nan":
        raw[0, 0, 0] = np.nan
    if fault == "score":
        raw[0, 0, 4] = 1.1
    if fault == "negative_width":
        raw[0, 0, 2] = -1
    if fault == "class":
        person = 80
    with pytest.raises(ModelContractError):
        person_candidates(raw, 0.1, person)


def test_letterbox_reverse_continuous_edges_and_clipping(metadata):
    original = np.array([[20.125, 10.5, 60.25, 50.75], [-10, -20, 210, 120]])
    transformed = original * 1.6 + [0, 80, 0, 80]
    result = reverse_letterbox(transformed, (200, 100), (1.6, 1.6), (0, 80))
    np.testing.assert_allclose(result[0], original[0], atol=1e-12)
    np.testing.assert_allclose(result[1], [0, 0, 200, 100])


@pytest.mark.parametrize("ratio,pad", [((0, 1), (0, 0)), ((1, 1), (-1, 0)), ((np.nan, 1), (0, 0))])
def test_bad_letterbox_transform(ratio, pad):
    with pytest.raises(ValueError):
        reverse_letterbox(np.ones((1, 4)), (200, 100), ratio, pad)


def test_nms_duplicates_ties_distinct_boxes_and_class_aware():
    rows = np.array(
        [
            [0, 0, 10, 10, 0.9, 0],
            [0, 0, 10, 10, 0.9, 0],
            [20, 0, 30, 10, 0.8, 0],
            [0, 0, 10, 10, 0.7, 1],
        ]
    )
    assert person_nms(rows) == [0, 2, 3]
    assert person_nms(rows, max_det=1) == [0]
    assert person_nms(np.empty((0, 6))) == []


def test_serialization_common_evaluator_and_seated_recall(labels, metadata):
    rows = np.array([[32, 96, 96, 160, 0.75, 0], [0, 0, 5, 5, 0.9, 0]])
    records = prediction_records(rows, "a.jpg", "yolov5n_320", metadata)
    assert len(records) == 1  # Padding-only box is clipped out.
    serialized = json.loads(json.dumps(records, allow_nan=False))
    assert serialized[0]["xmin"] == pytest.approx(20)
    assert serialized[0]["xmin_normalized"] == pytest.approx(0.1)
    images = [dict(labels["images"][0], predictions=serialized)]
    result = evaluate_configuration(images, labels, "yolov5n_320", 0.1)
    assert (result["true_positives"], result["false_positives"], result["false_negatives"]) == (
        1,
        0,
        0,
    )
    assert result["seated_recall"] == 1
    assert result["partial_recall"] is None
    result = evaluate_configuration(images, labels, "yolov5n_320", 0.8)
    assert result["false_negatives"] == 1
    assert result["precision"] is None


def test_incomplete_or_mismatched_inventory_rejected(labels):
    images = [dict(labels["images"][0], predictions=[])]
    labels["images"][0]["reviewed"] = False
    with pytest.raises(ValueError, match="human review"):
        evaluate_configuration(images, labels, "test", 0.1)
    labels["images"][0]["reviewed"] = True
    images[0]["source_sha256"] = "bad"
    with pytest.raises(ValueError, match="mismatch"):
        evaluate_configuration(images, labels, "test", 0.1)


def test_missing_and_malformed_model_artifacts(tmp_path):
    with pytest.raises(ModelContractError, match="weights"):
        verify_artifacts(tmp_path)
    (tmp_path / "yolov5n.pt").write_bytes(b"not a checkpoint")
    with pytest.raises(ModelContractError, match="weights"):
        verify_artifacts(tmp_path)


@pytest.mark.parametrize("size", [300, 640, True])
def test_initial_sizes_do_not_silently_substitute(size):
    with pytest.raises(ValueError, match="320 or 416"):
        YOLOv5n(size)


def test_annotation_completeness_does_not_invent_flags(labels):
    before = copy.deepcopy(labels)
    result = annotation_inventory(labels)
    assert result["flags"]["seated"]["true"] == 1
    assert result["flags"]["partial"]["false"] == 1
    assert result["flags"]["distant"]["missing"] == [1]
    assert labels == before


def test_pending_zone_sidecar_never_infers_vacancy(labels):
    sidecar = new_zone_labels(labels, "hash")
    validate_zone_labels(sidecar, labels, "hash")
    assert sidecar["persons"][0]["zone"] == UNKNOWN
    assert set(sidecar["images"][0]["zones"].values()) == {UNKNOWN}
    with pytest.raises(ValueError, match="reliable physical"):
        binary_zone_metrics(sidecar, {})


def test_zone_binary_pairs_unknown_exclusions_and_unresolved_predictions(labels):
    truth = new_zone_labels(labels, "hash")
    truth["physical_layout_verified"] = True
    states = dict(zip(ZONE_IDS, ["occupied", "vacant", UNKNOWN, "occupied"], strict=True))
    truth["images"][0]["zones"] = states
    predicted = {
        "mapping_physically_verified": True,
        "mapping_evidence": "synthetic unit fixture",
        "images": [
            {
                "image_id": 1,
                "source_sha256": truth["images"][0]["source_sha256"],
                "zones": dict(
                    zip(ZONE_IDS, ["vacant", "occupied", "occupied", UNKNOWN], strict=True)
                ),
            }
        ],
    }
    total = binary_zone_metrics(truth, predicted)["totals"]
    assert total["fn"] == total["fp"] == total["unknown_gt"] == total["unknown_prediction"] == 1
    assert total["false_vacancy_count"] == 1
    assert total["tn"] == 0
    assert total["occupied_zone_recall_including_unresolved"] == 0
    predicted["images"][0]["zones"][ZONE_IDS[0]] = "occupied"
    total = binary_zone_metrics(truth, predicted)["totals"]
    assert total["tp"] == 1
    assert total["recall"] == 1  # Conditional binary subset.
    assert total["occupied_zone_recall_including_unresolved"] == 0.5


def test_zone_inventory_review_and_contradiction_gates(labels):
    sidecar = new_zone_labels(labels, "hash")
    sidecar["persons"][0]["zone"] = ZONE_IDS[0]
    with pytest.raises(ValueError, match="reviewer"):
        validate_zone_labels(sidecar, labels, "hash")
    sidecar["persons"][0].update(reviewer="human", basis="known bench")
    sidecar["images"][0].update(reviewer="human", basis="room inspection")
    sidecar["images"][0]["zones"][ZONE_IDS[0]] = "vacant"
    with pytest.raises(ValueError, match="contradicts"):
        validate_zone_labels(sidecar, labels, "hash")
    with pytest.raises(ValueError, match="exact human"):
        validate_zone_labels(sidecar, labels, "different hash")


def test_experiment_has_no_appliance_activation_or_network(tmp_path, labels, monkeypatch):
    def forbidden(*args, **kwargs):
        raise AssertionError("Offline experiment attempted network or appliance control")

    monkeypatch.setattr(socket, "socket", forbidden)
    path = tmp_path / "labels.json"
    path.write_text(json.dumps(labels))
    output = tmp_path / "zones.json"
    assert main(["init", "--labels", str(path), "--output", str(output)]) == 0
    for name in ("experimental_detector.py", "phase4_comparison.py", "phase4_zones.py"):
        import ast

        tree = ast.parse((Path("src") / name).read_text())
        imports = [n.module for n in ast.walk(tree) if isinstance(n, ast.ImportFrom)]
        assert not set(imports) & {"camera", "mqtt_client", "main", "occupancy"}
    with pytest.raises(ValueError, match="preserved"):
        main(["init", "--labels", str(path), "--output", str(output)])


def test_saved_ssd_baseline_recomputed_all_configurations():
    cache = json.loads(Path("evaluation_baseline/ssd_run02_predictions.json").read_text())
    labels = json.loads(Path("evaluation_baseline/labels.coco.json").read_text())
    saved = json.loads(Path("outputs/phase3_diagnostics/evaluated_run_02/summary.json").read_text())
    reports, verification = baseline_verification(cache, labels, saved, Path("sample_images"))
    assert len(reports) == 24
    assert verification["all_24_configurations_verified"]
    best = max(reports, key=lambda r: r["f1"])
    assert (best["model_id"], best["threshold"]) == ("ssd_overlap", 0.4)
