import json
from pathlib import Path

from src.zone_review import (
    build_aisle_proposal,
    build_aisle_test_points,
    compare_expected_review,
    init_expected_review,
)

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "config/zones/diagnostic_six_zone.json"
PROPOSAL = ROOT / "config/zones/diagnostic_six_zone_aisle_proposal.json"
LABELS = ROOT / "outputs/dataset_diagnosis/review_set/ground_truth/labels.coco.json"
ASSIGNMENTS = ROOT / "outputs/zone_definition/person_zone_aisle_proposal/assignments.csv"


def test_proposal_has_continuous_partition_and_right_owned_aisle(tmp_path):
    proposal_path = tmp_path / "proposal.json"
    artifact_dir = tmp_path / "artifacts"
    proposal, validation = build_aisle_proposal(BASE, proposal_path, artifact_dir)
    assert validation["all_aisle_test_points_right_owned"]
    assert validation["partition_metrics"]["uncovered_area_px2_approx"] == 0
    assert validation["partition_metrics"]["interior_overlap_area_px2_approx"] == 0
    assert validation["old_divider_is_not_whole_aisle_test_pass"] is False
    assert any(point[0] < 0 for point in proposal["monitored_outer_region"]["polygon_px"])
    assert proposal["monitored_outer_region"]["diagnostic_clipped_polygon_px"]


def test_aisle_test_points_cover_each_depth_band():
    proposal = json.loads(PROPOSAL.read_text(encoding="utf-8"))
    rows = build_aisle_test_points(proposal)
    assert {row["band"] for row in rows} == {"far", "middle", "near"}
    assert all(row["assignment"]["zone"] == row["expected_right_zone"] for row in rows)


def test_manual_review_template_has_25_unreviewed_people(tmp_path):
    output = tmp_path / "expected.json"
    document = init_expected_review(LABELS, output)
    assert len(document["entries"]) == 25
    assert all(entry["expected_zone"] is None for entry in document["entries"])
    assert all(entry["review_status"] == "unreviewed" for entry in document["entries"])


def test_unreviewed_expected_labels_are_not_counted(tmp_path):
    review = tmp_path / "expected.json"
    init_expected_review(LABELS, review)
    report = compare_expected_review(review, ASSIGNMENTS, tmp_path / "comparison")
    assert report["reviewed_people"] == 0
    assert report["unreviewed_people_not_counted"] == 25
    assert report["heuristics"]["center"]["incorrect"] == 0
