import copy
import json
from dataclasses import replace

import pytest
from PIL import Image

from src.calibrate_zones import main as calibration_main
from src.calibrate_zones import reference_record, write_preview
from src.calibration import (
    CHECKS,
    CONFIRMATION_PHRASE,
    CalibrationSession,
    GroundPoint,
    PhysicalCalibration,
    confirm_document,
    geometry_digest,
    load_calibration,
    new_document,
)
from src.calibration_geometry import project
from src.config import REPO_ROOT, load_config
from src.main import main, update_zone_observation
from src.occupancy import OccupancyTracker
from src.zones import ZONE_IDS, ZoneMap


@pytest.fixture
def draft(tmp_path):
    path = tmp_path / "synthetic_reference.png"
    Image.new("RGB", (1000, 600), "gray").save(path)
    data = new_document(reference_record(path))
    data["metadata"]["title"] = "Synthetic geometry test fixture; not a physical calibration"
    data["seating_rows"] = [
        {"id": "row", "image_points": [[0.1, 0.7], [0.9, 0.7]], "notes": "synthetic"}
    ]
    for key, (x, y) in zip(ZONE_IDS, ((0.1, 0.6), (0.6, 0.6), (0.1, 0.3), (0.6, 0.3)), strict=True):
        data["seat_regions"].append(
            {
                "id": key + "_seat",
                "zone_id": key,
                "row_id": "row",
                "polygon": [[x, y], [x + 0.2, y], [x + 0.2, y + 0.2], [x, y + 0.2]],
                "floor_point": None,
            }
        )
    data["excluded_regions"] = [{"id": "ceiling", "polygon": [[0, 0], [1, 0], [1, 0.2], [0, 0.2]]}]
    return data, path


def confirmed_fixture(data):
    """Synthetic manual attestation fixture only; never touches a repository calibration."""
    data = copy.deepcopy(data)
    data["reference"].update(kind="mounted_pi", camera_id="SYNTHETIC", pose_id="SYNTHETIC")
    data["confirmation"]["checks"] = dict.fromkeys(CHECKS, True)
    return confirm_document(
        data,
        reviewer="Synthetic test fixture",
        phrase=CONFIRMATION_PHRASE,
        preview_digest=geometry_digest(data),
    )


def ground_draft(data):
    data = copy.deepcopy(data)
    data["assignment"]["method"] = "ground_plane"
    image = ((0.2, 0.9), (0.8, 0.9), (0.6, 0.5), (0.4, 0.5))
    floor = ((0, 0), (1, 0), (1, 1), (0, 1))
    data["floor_landmarks"] = [
        {"id": str(i), "image": list(p), "floor": list(q), "on_floor": True}
        for i, (p, q) in enumerate(zip(image, floor, strict=True))
    ]
    return data


def test_drafts_never_provide_occupancy_even_when_preview_finds_a_seat(draft):
    data, _ = draft
    calibration = PhysicalCalibration(data)
    box = (0.62, 0.15, 0.78, 0.25)
    assert calibration.locate(box).reason == "calibration_pending"
    preview = calibration.locate(box, preview=True)
    assert preview.status == "preview" and preview.zone_id == "front_left"
    assert calibration.assign(box) is None
    assert calibration.observe([box], frame_size=(1000, 600)).counts is None
    with pytest.raises(ValueError, match="UNKNOWN"):
        calibration.count([box])


@pytest.mark.parametrize(
    "box,expected",
    [
        ((0.62, 0.15, 0.78, 0.25), "front_left"),
        ((0.62, 0.65, 0.78, 0.75), "front_right"),
        ((0.32, 0.15, 0.48, 0.25), "back_left"),
        ((0.32, 0.65, 0.48, 0.75), "back_right"),
    ],
)
def test_seat_assignment_maps_manually_named_regions_to_appliances(draft, box, expected):
    data, _ = draft
    calibration = PhysicalCalibration(confirmed_fixture(data))
    assignment = calibration.locate(box, frame_size=(1000, 600))
    assert assignment.status == "assigned" and assignment.zone_id == expected
    assert assignment.seat_id == expected + "_seat"
    assert assignment.image_anchor[1] == pytest.approx(box[0] + 0.25 * (box[2] - box[0]))


def test_seated_body_bottom_is_not_used_as_ground_or_assignment_anchor(draft):
    data, _ = draft
    calibration = PhysicalCalibration(confirmed_fixture(data))
    box = (0.61, 0.15, 1, 0.25)  # Upper-body anchor still inside front-left seat region.
    result = calibration.locate(box)
    assert result.zone_id == "front_left" and result.image_anchor[1] < 0.8
    data["assignment"]["anchor_fraction"] = [0.5, 1]
    assert PhysicalCalibration(confirmed_fixture(data)).locate(box).status == "unknown"
    ground = PhysicalCalibration(confirmed_fixture(ground_draft(data)))
    assert ground.locate(box).reason == "explicit_ground_contact_required"


@pytest.mark.parametrize(
    "box,reason",
    [
        ((0.01, 0.2, 0.1, 0.3), "excluded_nonoccupancy_region"),
        ((0.2, 0.4, 0.3, 0.5), "no_seat_region"),
        ((0.6, 0.05, 0.8, 0.15), "seat_boundary_uncertain"),  # Anchor exactly at x=.1 boundary.
        ((0.7, 0.1, 0.7, 0.2), "invalid_person_box"),
        ((0.7, 0.1, float("nan"), 0.2), "invalid_person_box"),
    ],
)
def test_unknown_reasons_are_explicit_and_never_choose_nearest_region(draft, box, reason):
    data, _ = draft
    result = PhysicalCalibration(confirmed_fixture(data)).locate(box)
    assert result.zone_id is None and result.reason == reason


def test_ambiguous_overlap_is_unknown_even_if_seats_map_to_same_zone(draft):
    data, _ = draft
    duplicate = dict(data["seat_regions"][0], id="overlapping_seat")
    data["seat_regions"].append(duplicate)
    assert (
        PhysicalCalibration(confirmed_fixture(data)).locate((0.62, 0.15, 0.78, 0.25)).reason
        == "ambiguous_seat_regions"
    )


def test_exclusions_win_over_a_seat_mask(draft):
    data, _ = draft
    data["excluded_regions"].append({"id": "window", "polygon": data["seat_regions"][0]["polygon"]})
    result = PhysicalCalibration(confirmed_fixture(data)).locate((0.62, 0.15, 0.78, 0.25))
    assert result.reason == "excluded_nonoccupancy_region"


def test_ground_assignment_requires_explicit_contact_and_rejects_extrapolation(draft):
    data, _ = draft
    calibration = PhysicalCalibration(confirmed_fixture(ground_draft(data)))
    p = project(calibration.homography["inverse"], (0.25, 0.25))
    result = calibration.locate(ground_point=GroundPoint(p, "manual_floor_contact"))
    assert result.zone_id == "front_left" and result.floor_anchor == pytest.approx((0.25, 0.25))
    outside = calibration.locate(ground_point=GroundPoint((0.95, 0.7), "external_floor_estimate"))
    assert outside.reason == "outside_floor_reference_domain"
    boundary = project(calibration.homography["inverse"], (0.5, 0.25))
    assert (
        calibration.locate(ground_point=GroundPoint(boundary, "manual_floor_contact")).status
        == "unknown"
    )


def test_ground_contact_uncertainty_cannot_cross_a_physical_zone_boundary(draft):
    data, _ = draft
    calibration = PhysicalCalibration(confirmed_fixture(ground_draft(data)))
    p = project(calibration.homography["inverse"], (0.47, 0.25))
    assert (
        calibration.locate(ground_point=GroundPoint(p, "manual_floor_contact")).status == "assigned"
    )
    assert (
        calibration.locate(ground_point=GroundPoint(p, "manual_floor_contact", 30)).status
        == "unknown"
    )
    with pytest.raises(ValueError, match="provenance"):
        GroundPoint(p, "bbox_bottom")


@pytest.mark.parametrize(
    "problem",
    [
        "version",
        "bool",
        "zone",
        "zone_overlap",
        "seat_row",
        "floor_marker",
        "unknown_key",
        "landmark",
        "margin",
        "anchor",
        "duplicate",
    ],
)
def test_invalid_schema_or_geometry_fails_closed(draft, problem):
    data, _ = draft
    if problem == "version":
        data["schema_version"] = 99
    elif problem == "bool":
        data["calibrated"] = "false"
    elif problem == "zone":
        data["appliance_zones"][0]["id"] = "ceiling"
    elif problem == "zone_overlap":
        data["appliance_zones"][1]["floor_polygon"] = data["appliance_zones"][0]["floor_polygon"]
    elif problem == "seat_row":
        data["seat_regions"][0]["row_id"] = "missing"
    elif problem == "floor_marker":
        data["seat_regions"][0]["floor_point"] = [0.75, 0.75]
    elif problem == "unknown_key":
        data["guess"] = 123
    elif problem == "landmark":
        data["floor_landmarks"] = [
            {"id": "a", "image": [0, 0], "floor": [0, 0], "on_floor": "true"}
        ]
    elif problem == "margin":
        data["assignment"]["boundary_margin_px"] = -1
    elif problem == "anchor":
        data["assignment"]["anchor_fraction"] = [0.5, float("nan")]
    else:
        data["seat_regions"].append(data["seat_regions"][0])
    with pytest.raises(ValueError):
        PhysicalCalibration(data)


def test_inappropriate_landmarks_cannot_confirm_ground_calibration(draft):
    data, _ = draft
    data = ground_draft(data)
    data["floor_landmarks"][0]["on_floor"] = False
    calibration = PhysicalCalibration(data)
    assert calibration.homography is None
    with pytest.raises(ValueError, match="ground mode"):
        confirmed_fixture(data)


def test_confirmation_requires_mounted_reference_explicit_phrase_and_current_preview(draft):
    data, _ = draft
    data["confirmation"]["checks"] = dict.fromkeys(CHECKS, True)
    with pytest.raises(ValueError, match="mounted Pi"):
        confirm_document(
            data, reviewer="Test", phrase=CONFIRMATION_PHRASE, preview_digest=geometry_digest(data)
        )
    mounted = confirmed_fixture(data)
    mounted["calibrated"] = False
    with pytest.raises(ValueError, match="Explicit confirmation"):
        confirm_document(
            mounted, reviewer="Test", phrase="yes", preview_digest=geometry_digest(mounted)
        )
    with pytest.raises(ValueError, match="current preview"):
        confirm_document(
            mounted, reviewer="Test", phrase=CONFIRMATION_PHRASE, preview_digest="stale"
        )


def test_geometry_modification_invalidates_confirmed_file(draft):
    data, _ = draft
    approved = confirmed_fixture(data)
    approved["assignment"]["anchor_fraction"] = [0.5, 0.3]
    with pytest.raises(ValueError, match="changed since"):
        PhysicalCalibration(approved)


@pytest.mark.parametrize("suffix", [".yaml", ".json"])
def test_serialization_revisions_backups_and_undo_preserve_drafts(draft, tmp_path, suffix):
    data, _ = draft
    session = CalibrationSession(data)
    path = tmp_path / f"calibration{suffix}"
    session.save(path)
    original = path.read_bytes()
    assert load_calibration(path).to_dict()["revision"] == 1
    assert not ZoneMap.load(path).calibrated
    edit = copy.deepcopy(session.data)
    edit["assignment"]["anchor_fraction"] = [0.5, 0.4]
    session.replace(edit)
    session.save(path)
    assert load_calibration(path).to_dict()["revision"] == 2
    assert original in [
        p.read_bytes() for p in (tmp_path / f"calibration{suffix}.backups").iterdir()
    ]
    session.undo()
    assert session.data["assignment"]["anchor_fraction"] == [0.5, 0.25]
    assert not session.data["calibrated"] and session.previewed_digest is None
    session.save(path)
    assert load_calibration(path).to_dict()["revision"] == 3


def test_undo_and_settings_do_not_reinstate_manual_approval(draft):
    data, _ = draft
    session = CalibrationSession(confirmed_fixture(data))
    edit = session.data.copy()
    edit["metadata"] = dict(edit["metadata"], notes="changed")
    session.replace(edit)
    assert not session.data["calibrated"]
    session.undo()
    assert not session.data["calibrated"]
    assert session.data["confirmation"]["reviewer"] == ""


def test_session_confirmation_needs_current_preview_and_manual_checks(draft):
    data, _ = draft
    mounted = confirmed_fixture(data)
    mounted["calibrated"] = False
    session = CalibrationSession(mounted)
    checks = dict.fromkeys(CHECKS, True)
    with pytest.raises(ValueError, match="current preview"):
        session.confirm("Synthetic fixture", CONFIRMATION_PHRASE, checks)
    session.mark_previewed()
    incomplete = dict(checks, anchors=False)
    with pytest.raises(ValueError, match="manual checks"):
        session.confirm("Synthetic fixture", CONFIRMATION_PHRASE, incomplete)
    session.confirm("Synthetic fixture", CONFIRMATION_PHRASE, checks)
    assert session.data["calibrated"]
    edited = session.data.copy()
    edited["assignment"] = dict(edited["assignment"], boundary_margin_px=5)
    session.replace(edited)
    assert session.previewed_digest is None and not session.data["calibrated"]


def test_seat_coverage_for_all_appliances_required_before_confirmation(draft):
    data, _ = draft
    data["seat_regions"].pop()
    with pytest.raises(ValueError, match="all four"):
        confirmed_fixture(data)


def test_unknown_observations_clear_occupancy_and_never_confirm_vacancy(draft):
    data, _ = draft
    calibration = PhysicalCalibration(confirmed_fixture(data))
    tracker = OccupancyTracker(load_config().occupancy)
    for now in (0, 0.5):
        update_zone_observation(tracker, calibration, [(0.62, 0.15, 0.78, 0.25)], now, (1000, 600))
    assert tracker.snapshot(0.5)["front_left"]["state"] == "occupied"
    for now in (1, 6, 12, 20):
        update_zone_observation(tracker, calibration, [(0.2, 0.4, 0.3, 0.5)], now, (1000, 600))
    assert tracker.last_observation is None
    assert all(
        z["state"] == "unknown" and z["person_count"] is None for z in tracker.snapshot(20).values()
    )


def test_mismatched_camera_geometry_and_frame_sizes_are_unknown(draft):
    data, _ = draft
    calibration = PhysicalCalibration(confirmed_fixture(data))
    camera = replace(load_config().camera, width=1000, height=600)
    calibration.validate_camera(camera)
    with pytest.raises(ValueError, match="size/flips"):
        calibration.validate_camera(replace(camera, hflip=True))
    assert (
        calibration.locate((0.62, 0.15, 0.78, 0.25), frame_size=(640, 480)).reason
        == "frame_size_mismatch"
    )
    assert calibration.observe([], frame_size=(640, 480)).counts is None


def test_confirmed_mismatched_camera_is_rejected_before_hardware_or_runtime(draft, monkeypatch):
    from src.main import run

    def forbidden(*args, **kwargs):
        raise AssertionError("Mismatched framing must fail before runtime allocation")

    monkeypatch.setattr("src.detector.create_detector", forbidden)
    data, _ = draft
    with pytest.raises(ValueError, match="size/flips"):
        run(load_config(), PhysicalCalibration(confirmed_fixture(data)))


def test_legacy_boolean_cannot_commission_example_image_polygons(monkeypatch):
    from src.main import run

    legacy = replace(ZoneMap.load(REPO_ROOT / "config/zones.yaml"), calibrated=True)

    def forbidden(*args, **kwargs):
        raise AssertionError("Legacy image geometry cannot start inference or control")

    monkeypatch.setattr("src.detector.create_detector", forbidden)
    with pytest.raises(ValueError, match="version-2 mounted-camera"):
        run(load_config(), legacy)


def test_preview_is_reference_bound_and_does_not_change_confirmation(draft, tmp_path):
    data, reference = draft
    output = tmp_path / "preview.png"
    report = write_preview(data, reference, output, boxes=[(0.62, 0.15, 0.78, 0.25)])
    assert report["assignments"][0]["status"] == "preview"
    assert not report["mqtt_used"] and not report["camera_used"] and not report["calibrated"]
    assert Image.open(output).size == (1600, 1000)
    different = tmp_path / "different.png"
    Image.new("RGB", (1000, 600), "red").save(different)
    with pytest.raises(ValueError, match="hash mismatch"):
        write_preview(data, different, output)


def test_preview_cannot_overwrite_a_source_or_calibration_sidecar(draft, tmp_path):
    data, reference = draft
    original = reference.read_bytes()
    with pytest.raises(ValueError, match="must not overwrite"):
        write_preview(data, reference, reference)
    assert reference.read_bytes() == original
    calibration = tmp_path / "room.json"
    CalibrationSession(data).save(calibration)
    before = calibration.read_bytes()
    with pytest.raises(ValueError, match="must not overwrite"):
        write_preview(data, reference, tmp_path / "room.png", calibration_path=calibration)
    assert calibration.read_bytes() == before


def test_ground_preview_serializes_fit_quality_without_projecting_box_bottoms(draft, tmp_path):
    data, reference = draft
    data = ground_draft(data)
    calibration = PhysicalCalibration(data)
    floor_contact = project(calibration.homography["inverse"], (0.25, 0.25))
    report = write_preview(
        data,
        reference,
        tmp_path / "ground.png",
        ground_points=[GroundPoint(floor_contact, "manual_floor_contact")],
    )
    assert not report["calibrated"] and report["homography"]["reference_count"] == 4
    assert report["assignments"][0]["status"] == "preview"
    assert report["assignments"][0]["zone_id"] == "front_left"


def test_supplied_photographs_cannot_be_promoted_to_mounted_reference():
    with pytest.raises(ValueError, match="illustrative"):
        reference_record(REPO_ROOT / "sample_images/IMG_20261013_133640.jpg", mounted=True)


def test_calibration_cli_and_gate_never_create_mqtt_or_camera(draft, tmp_path, monkeypatch):
    data, image = draft

    def forbidden(*args, **kwargs):
        raise AssertionError("Calibration must not open MQTT, camera or an interpreter")

    monkeypatch.setattr("src.mqtt_client.MQTTPublisher.__init__", forbidden)
    monkeypatch.setattr("src.camera.PiCamera.__init__", forbidden)
    monkeypatch.setattr("src.detector.create_detector", forbidden)
    path = tmp_path / "calibration.json"
    assert calibration_main(["init", "--image", str(image), "--calibration", str(path)]) == 0
    assert calibration_main(["preview", "--image", str(image), "--calibration", str(path)]) == 0
    from src.main import run

    with pytest.raises(ValueError, match="calibrated:true"):
        run(load_config(), PhysicalCalibration(data))
    assert main(["run"]) == 1  # Existing legacy safety gate remains closed.
    assert not json.loads(path.read_text())["calibrated"]
