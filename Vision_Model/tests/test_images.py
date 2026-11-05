import numpy as np
import pytest
from PIL import Image

from src.config import REPO_ROOT
from src.detector import Detection
from src.images import (
    ImageFolder,
    UnreadableImageError,
    annotate_image,
    detection_record,
    load_rgb_image,
)
from src.zones import ZoneMap


def test_discovery_is_sorted_case_insensitive_nonrecursive_and_filters_extensions(tmp_path):
    for name in ("b.JPG", "A.jpeg", "c.png", "ignored.txt"):
        (tmp_path / name).touch()
    (tmp_path / "directory.jpg").mkdir()
    (tmp_path / "nested").mkdir()
    (tmp_path / "nested/hidden.jpg").touch()
    assert [p.name for p in ImageFolder(tmp_path).discover()] == ["A.jpeg", "b.JPG", "c.png"]


@pytest.mark.parametrize("kind", ["missing", "empty", "file"])
def test_invalid_image_folder(tmp_path, kind):
    path = tmp_path / "input"
    if kind == "empty":
        path.mkdir()
    elif kind == "file":
        path.write_text("not a folder")
    with pytest.raises(ValueError):
        ImageFolder(path).discover()


@pytest.mark.parametrize("mode", ["RGB", "RGBA", "L"])
def test_loading_produces_rgb_uint8_without_channel_swap(tmp_path, mode):
    path = tmp_path / "image.png"
    color = {"RGB": (240, 10, 30), "RGBA": (240, 10, 30, 255), "L": 77}[mode]
    Image.new(mode, (8, 6), color).save(path)
    loaded = load_rgb_image(path)
    assert loaded.image.mode == "RGB"
    assert loaded.rgb.shape == (6, 8, 3) and loaded.rgb.dtype == np.uint8
    np.testing.assert_array_equal(loaded.rgb[0, 0], [77] * 3 if mode == "L" else [240, 10, 30])


def test_exif_orientation_is_applied_before_coordinate_frame_is_established(tmp_path):
    path = tmp_path / "rotated.jpg"
    exif = Image.Exif()
    exif[274] = 6
    Image.new("RGB", (12, 8), "red").save(path, exif=exif)
    loaded = load_rgb_image(path)
    assert loaded.encoded_size == (12, 8)
    assert loaded.image.size == (8, 12)
    assert loaded.exif_orientation == 6
    assert loaded.image.getexif().get(274) is None


@pytest.mark.parametrize("contents", [b"", b"not an image", b"\x89PNG\r\n\x1a\ntruncated"])
def test_corrupt_images_have_explicit_errors(tmp_path, contents):
    path = tmp_path / "bad.jpg"
    path.write_bytes(contents)
    with pytest.raises(UnreadableImageError, match="bad.jpg"):
        load_rgb_image(path)


def test_missing_image_has_explicit_error(tmp_path):
    with pytest.raises(UnreadableImageError):
        load_rgb_image(tmp_path / "missing.png")


def test_coordinate_conversion_has_pixels_normalized_edges_and_centers():
    row = detection_record("photo.jpg", 1, Detection((0.2, 0.1, 0.8, 0.9), 0.9, 0), (100, 50))
    assert [row[k] for k in ("xmin", "ymin", "xmax", "ymax")] == pytest.approx([10, 10, 90, 40])
    assert [row["center_x"], row["center_y"]] == pytest.approx([50, 25])
    assert row["xmin_normalized"] == 0.1
    assert row["center_y_normalized"] == 0.5
    full = detection_record("full.png", 1, Detection((0, 0, 1, 1), 0.9, 0), (100, 50))
    assert full["xmax"] == 100 and full["ymax"] == 50


@pytest.mark.parametrize(
    "box,size",
    [((0, 0, 1.1, 1), (100, 50)), ((0, 0, 1, 1), (0, 50)), ((0.8, 0, 0.2, 1), (100, 50))],
)
def test_bad_coordinate_conversion_is_rejected(box, size):
    with pytest.raises(ValueError):
        detection_record("bad", 1, Detection(box, 0.9, 0), size)


def test_annotation_draws_boxes_on_a_copy_and_can_be_saved(tmp_path):
    original = Image.new("RGB", (200, 100), "white")
    row = detection_record("photo.jpg", 1, Detection((0.2, 0.25, 0.9, 0.75), 0.9, 0), original.size)
    annotated = annotate_image(original, [row])
    assert original.getpixel((149, 89)) == (255, 255, 255)
    assert annotated.getpixel((149, 89)) == (0, 255, 0)
    annotated.save(tmp_path / "annotated.png")
    with Image.open(tmp_path / "annotated.png") as saved:
        assert saved.size == original.size


def test_zone_overlay_does_not_change_calibration_state():
    zones = ZoneMap.load(REPO_ROOT / "config/zones.yaml")
    image = Image.new("RGB", (640, 480), "white")
    annotated = annotate_image(image, [], zones)
    assert not zones.calibrated
    assert np.any(np.asarray(annotated) != np.asarray(image))
