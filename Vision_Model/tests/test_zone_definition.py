import json
from pathlib import Path

from PIL import Image

from src.zone_definition import (
    assign_point,
    load_config,
    person_zone_preview,
    read_svg_geometry,
    validate_config,
    validate_frame,
)

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "config/zones/diagnostic_six_zone.json"


def test_svg_conversion_and_reference_hash_are_recorded():
    config = load_config(CONFIG)
    geometry = read_svg_geometry(ROOT / "config/zones/zone_layout.svg")
    assert geometry["view_box"] == [0.0, 0.0, 2145.45, 1440.0]
    assert geometry["embedded_image"]["x"] == 101.68
    assert config["reference"]["width"] == 1920
    assert config["reference"]["height"] == 1440
    assert config["source_svg"]["svg_to_image"]["offset_x"] == -101.68
    assert config["reference"]["sha256"]


def test_shared_aisle_edge_has_right_zone_ownership():
    config = load_config(CONFIG)
    z1 = next(zone for zone in config["zones"] if zone["id"] == "Z1")["polygon_px"]
    z2 = next(zone for zone in config["zones"] if zone["id"] == "Z2")["polygon_px"]
    point = ((z1[0][0] + z2[1][0]) / 2, (z1[0][1] + z2[1][1]) / 2)
    assignment = assign_point(config, point)
    assert assignment["zone"] == "Z1"
    assert assignment["status"] in {"assigned", "boundary_ambiguous"}


def test_track_history_retains_previous_zone_near_shared_edge_and_rescales():
    config = load_config(CONFIG)
    z1 = next(zone for zone in config["zones"] if zone["id"] == "Z1")["polygon_norm"]
    point = (
        sum(vertex[0] for vertex in z1) / len(z1) * 960,
        sum(vertex[1] for vertex in z1) / len(z1) * 720,
    )
    resized_assignment = assign_point(config, point, frame_size=(960, 720))
    assert resized_assignment["zone"] == "Z1"
    assert resized_assignment["tolerance_px_used"] == 6
    assert assign_point(config, point, frame_size=(1920, 1440))["tolerance_px_used"] == 12
    edge = next(zone for zone in config["zones"] if zone["id"] == "Z1")["polygon_px"][0]
    retained = assign_point(config, tuple(edge), previous_zone="Z2", track_id="track-1")
    assert retained["zone"] == "Z2"
    assert retained["reason"] == "track_history_retained_within_tolerance_band"


def test_outside_and_aspect_ratio_are_explicit(tmp_path):
    config = load_config(CONFIG)
    outside = assign_point(config, (10, 10))
    assert outside["status"] == "outside_zone"
    image = tmp_path / "changed.png"
    Image.new("RGB", (1000, 700), "black").save(image)
    result = validate_frame(config, image)
    assert result["status"] == "reject_aspect_ratio_or_crop_changed"
    same_aspect = tmp_path / "rescaled.png"
    Image.new("RGB", (960, 720), "black").save(same_aspect)
    assert (
        validate_frame(config, same_aspect)["status"] == "ok_rescaled_same_aspect_manual_crop_check"
    )


def test_empty_prediction_frame_is_kept_in_assignment_json(tmp_path):
    labels = {
        "images": [{"id": 1, "file_name": "empty.png", "width": 1920, "height": 1440}],
        "annotations": [],
    }
    labels_path = tmp_path / "labels.json"
    labels_path.write_text(json.dumps(labels), encoding="utf-8")
    predictions_path = tmp_path / "predictions.json"
    predictions_path.write_text(
        json.dumps({"frames": [{"file": "empty.png", "detections": []}]}), encoding="utf-8"
    )
    images = tmp_path / "images"
    images.mkdir()
    Image.new("RGB", (1920, 1440), "black").save(images / "empty.png")
    output = tmp_path / "preview"
    person_zone_preview(CONFIG, labels_path, predictions_path, images, output, [])
    rows = json.loads((output / "assignments.json").read_text(encoding="utf-8"))
    frame_rows = [row for row in rows if row.get("record_type") == "frame"]
    assert len(frame_rows) == 1
    assert frame_rows[0]["image_status"]["status"] == "ok_same_capture_geometry_content_differs"


def test_config_validation_reports_clean_geometry():
    assert validate_config(load_config(CONFIG))["interior_crossings"] == 0
