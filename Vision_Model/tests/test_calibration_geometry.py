import numpy as np
import pytest

from src.calibration_geometry import (
    convex_clip,
    fit_homography,
    inside_margin,
    point,
    polygon,
    project,
)
from src.calibration_preview import FLOOR_RECT, image_rect, inverse_view, view_point

IMAGE = ((0.2, 0.9), (0.8, 0.9), (0.6, 0.5), (0.4, 0.5))
FLOOR = ((0, 0), (1, 0), (1, 1), (0, 1))


def test_homography_maps_perspective_landmarks_and_round_trips_interior():
    h = fit_homography(IMAGE, FLOOR, (640, 480))
    assert h["reference_count"] == 4
    assert h["max_error_px"] < 1e-8
    for p, q in zip(IMAGE, FLOOR, strict=True):
        assert project(h["matrix"], p) == pytest.approx(q)
    world = (0.23, 0.76)
    pixel = project(h["inverse"], world)
    assert project(h["matrix"], pixel) == pytest.approx(world)


def test_homography_uses_more_than_four_measured_correspondences():
    h = fit_homography(IMAGE, FLOOR)
    more_floor = (*FLOOR, (0.2, 0.4), (0.7, 0.6))
    more_image = tuple(project(h["inverse"], p) for p in more_floor)
    fitted = fit_homography(more_image, more_floor, (640, 480))
    assert fitted["reference_count"] == 6
    assert fitted["rms_error_px"] < 1e-8


@pytest.mark.parametrize(
    "problem", ["few", "collinear_image", "collinear_floor", "repeated", "nan", "bad_pair"]
)
def test_bad_homography_landmarks_rejected(problem):
    image, floor = list(IMAGE), list(FLOOR)
    if problem == "few":
        image, floor = image[:3], floor[:3]
    elif problem == "collinear_image":
        image = [(0, 0), (0.25, 0.25), (0.5, 0.5), (1, 1)]
    elif problem == "collinear_floor":
        floor = [(0, 0), (0.25, 0.25), (0.5, 0.5), (1, 1)]
    elif problem == "repeated":
        image[-1] = image[0]
    elif problem == "nan":
        image[0] = (float("nan"), 0)
    else:
        floor.pop()
    with pytest.raises(ValueError):
        fit_homography(image, floor)


def test_inconsistent_reference_points_fail_reprojection_limit():
    image = (*IMAGE, (0.5, 0.71))
    floor = (*FLOOR, (0.2, 0.8))
    with pytest.raises(ValueError, match="reprojection"):
        fit_homography(image, floor, (1000, 600), max_error_px=0.1)


def test_horizon_is_rejected_instead_of_returning_infinite_coordinates():
    matrix = np.array([[1, 0, 0], [0, 1, 0], [1, 0, -0.5]])
    with pytest.raises(ValueError, match="horizon"):
        project(matrix, (0.5, 0.5))


@pytest.mark.parametrize("value", [(0, True), (1.01, 0), (-0.01, 0), (0, float("inf")), (0,), "xy"])
def test_normalized_points_reject_bad_values(value):
    with pytest.raises(ValueError):
        point(value)


@pytest.mark.parametrize(
    "vertices",
    [
        [[0, 0], [1, 1], [1, 0], [0, 1]],
        [[0, 0], [1, 0], [0.3, 0.3], [0, 1]],
        [[0, 0], [0.5, 0], [1, 0]],
        [[0, 0], [1, 0], [1, 0]],
    ],
)
def test_nonconvex_or_degenerate_regions_fail(vertices):
    with pytest.raises(ValueError):
        polygon(vertices, "test")


def test_margin_is_in_reference_pixels_and_boundaries_are_unknown():
    assert inside_margin((0.5, 0.5), FLOOR, 4, (640, 480))
    assert not inside_margin((0.001, 0.5), FLOOR, 4, (640, 480))
    assert not inside_margin((0, 0.5), FLOOR, 0)
    assert inside_margin((0.01, 0.5), FLOOR, 4, (640, 480))


def test_floor_projection_is_clipped_to_measured_domain():
    subject = ((0, 0), (0.5, 0), (0.5, 1), (0, 1))
    clip = ((0.1, 0.1), (0.9, 0.1), (0.9, 0.9), (0.1, 0.9))
    for winding in (clip, clip[::-1]):
        result = convex_clip(subject, winding)
        assert result
        assert all(
            0.1 - 1e-9 <= x <= 0.5 + 1e-9 and 0.1 - 1e-9 <= y <= 0.9 + 1e-9 for x, y in result
        )


def test_editor_image_and_floor_coordinates_round_trip_with_front_at_bottom():
    rect = image_rect((3264, 1836))
    p = (0.3, 0.7)
    assert inverse_view(view_point(p, rect), rect) == pytest.approx(p)
    assert inverse_view(
        view_point(p, FLOOR_RECT, floor=True), FLOOR_RECT, floor=True
    ) == pytest.approx(p)
    assert view_point((0, 0), FLOOR_RECT, floor=True)[1] == FLOOR_RECT[3]
    assert inverse_view((-100, -100), rect) is None
