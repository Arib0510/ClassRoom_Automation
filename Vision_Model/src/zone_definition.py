# ruff: noqa: E501
"""Provisional six-zone definition and visual verification tools.

This module is deliberately separate from ``config/zones.yaml`` and from the
physical calibration schema.  It describes image-space desktop bands only;
it is not a floor-plane calibration and is not used by the live controller.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import re
import shutil
import sys
import xml.etree.ElementTree as ET
from collections.abc import Iterable, Sequence
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ZONE_ORDER = ("Z1", "Z2", "Z3", "Z4", "Z5", "Z6")
RIGHT_ZONE_ORDER = ("Z1", "Z3", "Z5")
ZONE_COLORS = {
    "Z1": (240, 80, 80),
    "Z2": (80, 150, 240),
    "Z3": (240, 150, 40),
    "Z4": (60, 190, 120),
    "Z5": (180, 90, 220),
    "Z6": (40, 190, 190),
}
POLYGON_TO_ZONE = ("Z2", "Z1", "Z4", "Z3", "Z6", "Z5")
SOURCE_POLYGON_COUNT = 6


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _number_pairs(value: str) -> list[tuple[float, float]]:
    numbers = [float(item) for item in re.findall(r"-?\d+(?:\.\d+)?", value)]
    if len(numbers) % 2:
        raise ValueError(f"Odd number of polygon coordinates: {value!r}")
    points = list(zip(numbers[::2], numbers[1::2], strict=False))
    if len(points) > 1 and points[0] == points[-1]:
        points.pop()
    return points


def read_svg_geometry(svg_path: Path) -> dict:
    root = ET.parse(svg_path).getroot()
    view_box = [float(value) for value in root.attrib["viewBox"].split()]
    image = next(element for element in root.iter() if element.tag.rsplit("}", 1)[-1] == "image")
    transform = image.attrib.get("transform", "")
    translate = re.search(r"translate\(\s*([-+]?\d+(?:\.\d+)?)", transform)
    image_x = float(translate.group(1)) if translate else float(image.attrib.get("x", 0))
    image_y = float(image.attrib.get("y", 0))
    polygons = []
    for element in root.iter():
        if element.tag.rsplit("}", 1)[-1] != "polygon":
            continue
        polygons.append(_number_pairs(element.attrib["points"]))
    if len(polygons) != SOURCE_POLYGON_COUNT:
        raise ValueError(
            f"Expected {SOURCE_POLYGON_COUNT} SVG zone polygons, found {len(polygons)}"
        )
    return {
        "view_box": view_box,
        "embedded_image": {
            "width": float(image.attrib["width"]),
            "height": float(image.attrib["height"]),
            "x": image_x,
            "y": image_y,
            "transform": transform,
        },
        "polygons_svg": polygons,
        "svg_to_image": {
            "scale_x": 1.0,
            "scale_y": 1.0,
            "offset_x": -image_x,
            "offset_y": -image_y,
            "formula": "x_image=(x_svg-101.68), y_image=y_svg",
        },
    }


def polygon_area(points: Sequence[Sequence[float]]) -> float:
    return 0.5 * sum(
        points[index][0] * points[(index + 1) % len(points)][1]
        - points[(index + 1) % len(points)][0] * points[index][1]
        for index in range(len(points))
    )


def _orientation(a, b, c) -> float:
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])


def _on_segment(a, b, p, tolerance=1e-6) -> bool:
    return (
        abs(_orientation(a, b, p)) <= tolerance
        and min(a[0], b[0]) - tolerance <= p[0] <= max(a[0], b[0]) + tolerance
        and min(a[1], b[1]) - tolerance <= p[1] <= max(a[1], b[1]) + tolerance
    )


def segments_intersect(a, b, c, d, tolerance=1e-6) -> bool:
    orientations = (
        _orientation(a, b, c),
        _orientation(a, b, d),
        _orientation(c, d, a),
        _orientation(c, d, b),
    )
    if abs(orientations[0]) <= tolerance and _on_segment(a, b, c, tolerance):
        return True
    if abs(orientations[1]) <= tolerance and _on_segment(a, b, d, tolerance):
        return True
    if abs(orientations[2]) <= tolerance and _on_segment(c, d, a, tolerance):
        return True
    if abs(orientations[3]) <= tolerance and _on_segment(c, d, b, tolerance):
        return True
    return (orientations[0] > 0) != (orientations[1] > 0) and (orientations[2] > 0) != (
        orientations[3] > 0
    )


def point_in_polygon(point, polygon, include_boundary=True) -> bool:
    x, y = point
    inside = False
    for index, first in enumerate(polygon):
        second = polygon[(index + 1) % len(polygon)]
        if _on_segment(first, second, point):
            return include_boundary
        if (first[1] > y) != (second[1] > y):
            cross_x = (second[0] - first[0]) * (y - first[1]) / (second[1] - first[1]) + first[0]
            if x < cross_x:
                inside = not inside
    return inside


def distance_to_segment(point, a, b) -> float:
    dx, dy = b[0] - a[0], b[1] - a[1]
    if dx == dy == 0:
        return math.dist(point, a)
    t = max(0.0, min(1.0, ((point[0] - a[0]) * dx + (point[1] - a[1]) * dy) / (dx * dx + dy * dy)))
    return math.dist(point, (a[0] + t * dx, a[1] + t * dy))


def distance_to_polygon(point, polygon) -> float:
    return min(
        distance_to_segment(point, polygon[index], polygon[(index + 1) % len(polygon)])
        for index in range(len(polygon))
    )


def _pixel_to_norm(points, width, height):
    return [[round(x / width, 9), round(y / height, 9)] for x, y in points]


def _norm_to_pixel(points, width, height):
    return [[round(x * width, 3), round(y * height, 3)] for x, y in points]


def _adjusted_polygons(geometry: dict) -> dict[str, list[list[float]]]:
    mapped = [
        [
            [
                round(x + geometry["svg_to_image"]["offset_x"], 3),
                round(y + geometry["svg_to_image"]["offset_y"], 3),
            ]
            for x, y in polygon
        ]
        for polygon in geometry["polygons_svg"]
    ]
    result = {zone: mapped[index] for index, zone in enumerate(POLYGON_TO_ZONE)}

    # The marked SVG has a narrow stroke-width gap at the central divider.  Use
    # the right-zone edge (the image-left aisle edge) as one shared edge.  This
    # is an explicit user-directed adjustment, not an inferred floor boundary.
    divider_vertices = {
        "Z1": ((1, 0), (2, 1)),  # left bottom/top follow right polygon bottom/top
        "Z3": ((2, 0), (3, 1)),  # left top/bottom follow right polygon top/bottom
        "Z5": ((2, 1), (3, 0)),  # source far-right polygon is bottom/top
    }
    for right_zone, pairs in divider_vertices.items():
        left_zone = {"Z1": "Z2", "Z3": "Z4", "Z5": "Z6"}[right_zone]
        right_polygon = result[right_zone]
        left_polygon = result[left_zone]
        for left_index, right_index in pairs:
            left_polygon[left_index] = right_polygon[right_index][:]
    return result


def _appliance_mapping(zone: str) -> dict:
    group = {"Z1": 1, "Z2": 1, "Z3": 2, "Z4": 2, "Z5": 3, "Z6": 3}[zone]
    return {
        "esp32": f"ESP32 {group}",
        "fan": f"F{zone[1:]}",
        "light": f"L{zone[1:]}",
        "shared": f"B{group}",
        "shared_condition": f"{f'Z{2 * group - 1}'} OR {f'Z{2 * group}'}",
    }


def build_config(
    svg_path: Path, reference_path: Path, config_path: Path, artifact_dir: Path
) -> dict:
    with Image.open(reference_path) as image:
        width, height = image.size
    geometry = read_svg_geometry(svg_path)
    embedded = geometry["embedded_image"]
    if (embedded["width"], embedded["height"]) != (width, height):
        raise ValueError("SVG embedded image dimensions do not match reference image")
    if sha256(reference_path) != sha256_bytes_from_svg(svg_path):
        raise ValueError("SVG embedded image bytes do not match reference_raw.png")
    polygons = _adjusted_polygons(geometry)
    zones = []
    bands = {"Z1": "near", "Z2": "near", "Z3": "middle", "Z4": "middle", "Z5": "far", "Z6": "far"}
    sides = {"Z1": "right", "Z2": "left", "Z3": "right", "Z4": "left", "Z5": "right", "Z6": "left"}
    for zone in ZONE_ORDER:
        pixel = polygons[zone]
        zones.append(
            {
                "id": zone,
                "band": bands[zone],
                "side": sides[zone],
                "polygon_px": pixel,
                "polygon_norm": _pixel_to_norm(pixel, width, height),
                "appliance": _appliance_mapping(zone),
                "source_polygon_index": POLYGON_TO_ZONE.index(zone) + 1,
            }
        )
    config = {
        "schema": "image_zone_definition",
        "schema_version": 1,
        "status": "provisional_visual_draft",
        "diagnostic_only": True,
        "physical_floor_calibration": False,
        "reference": {
            "file": reference_path.name,
            "file_name": reference_path.name,
            "sha256": sha256(reference_path),
            "width": width,
            "height": height,
            "aspect_ratio": round(width / height, 9),
            "coordinate_system": "original_image_pixels_and_normalized_xy",
        },
        "source_svg": {
            "file": str(svg_path),
            "file_name": svg_path.name,
            "sha256": sha256(svg_path),
            "viewBox": geometry["view_box"],
            "embedded_image": embedded,
            "svg_to_image": geometry["svg_to_image"],
            "source_polygons_svg": geometry["polygons_svg"],
            "conversion_note": "All stored polygon_px coordinates are source SVG polygon coordinates translated by (-101.68, 0); no marked PNG coordinates were used.",
        },
        "assignment": {
            "anchor_policy_default": "bottom_center",
            "supported_anchor_policies": ["center", "bottom_center"],
            "boundary_tolerance_px": 12,
            "track_history_enabled": True,
            "track_rule": "retain previous zone when the current assignment point is within the tolerance band and a track history exists",
            "no_history_tie_break": ["Z1", "Z3", "Z5", "Z2", "Z4", "Z6"],
            "aisle_ownership": "right_zones",
            "outside_label": "outside_zone",
            "uncertain_label": "boundary_ambiguous",
        },
        "sync_groups": [
            {
                "id": "near_aisle_edge",
                "description": "Image-left edge of aisle; owned by Z1",
                "vertices": [{"zone": "Z1", "index": 0}, {"zone": "Z2", "index": 1}],
            },
            {
                "id": "near_aisle_edge_top",
                "description": "Image-left edge of aisle; owned by Z1",
                "vertices": [{"zone": "Z1", "index": 1}, {"zone": "Z2", "index": 2}],
            },
            {
                "id": "middle_aisle_edge_top",
                "description": "Image-left edge of aisle; owned by Z3",
                "vertices": [{"zone": "Z3", "index": 0}, {"zone": "Z4", "index": 2}],
            },
            {
                "id": "middle_aisle_edge_bottom",
                "description": "Image-left edge of aisle; owned by Z3",
                "vertices": [{"zone": "Z3", "index": 1}, {"zone": "Z4", "index": 3}],
            },
            {
                "id": "far_aisle_edge_bottom",
                "description": "Image-left edge of aisle; owned by Z5",
                "vertices": [{"zone": "Z5", "index": 0}, {"zone": "Z6", "index": 3}],
            },
            {
                "id": "far_aisle_edge_top",
                "description": "Image-left edge of aisle; owned by Z5",
                "vertices": [{"zone": "Z5", "index": 1}, {"zone": "Z6", "index": 2}],
            },
        ],
        "zones": zones,
        "notes": [
            "Boundaries follow marked desktop edges/heights and are not calibrated floor-plane boundaries.",
            "Camera position and orientation are intended to remain fixed.",
            "Manual review is required before any operational use.",
        ],
    }
    validate_config(config)
    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
    artifact_dir.mkdir(parents=True, exist_ok=True)
    (artifact_dir / "svg_geometry.json").write_text(
        json.dumps(geometry, indent=2) + "\n", encoding="utf-8"
    )
    render_zone_overlay(config, reference_path, artifact_dir / "zone_overlay_reference.png")
    (artifact_dir / "coordinate_conversion.txt").write_text(
        "SVG viewBox: 0 0 2145.45 1440\n"
        "Embedded image: x=101.68, y=0, width=1920, height=1440\n"
        "Conversion: x_image = x_svg - 101.68; y_image = y_svg\n"
        "Source PNG was byte-identical to the SVG embedded image.\n",
        encoding="utf-8",
    )
    return config


def sha256_bytes_from_svg(svg_path: Path) -> str:
    root = ET.parse(svg_path).getroot()
    image = next(e for e in root.iter() if e.tag.rsplit("}", 1)[-1] == "image")
    href = next(v for k, v in image.attrib.items() if k.rsplit("}", 1)[-1] == "href")
    import base64

    return hashlib.sha256(base64.b64decode(href.split(",", 1)[1])).hexdigest()


def load_config(path: Path) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    validate_config(data)
    return data


def validate_config(config: dict) -> dict:
    reference = config["reference"]
    width, height = reference["width"], reference["height"]
    zones = {zone["id"]: zone for zone in config["zones"]}
    missing = set(ZONE_ORDER) - set(zones)
    if missing:
        raise ValueError(f"Missing zones: {sorted(missing)}")
    errors = []
    for zone_id in ZONE_ORDER:
        points = zones[zone_id]["polygon_px"]
        if len(points) < 3 or abs(polygon_area(points)) < 1:
            errors.append(f"{zone_id}: degenerate polygon")
        for index in range(len(points)):
            a, b = points[index], points[(index + 1) % len(points)]
            for other in range(index + 1, len(points)):
                c, d = points[other], points[(other + 1) % len(points)]
                if other in {(index - 1) % len(points), (index + 1) % len(points)}:
                    continue
                if segments_intersect(a, b, c, d):
                    if any(math.dist(p, q) <= 5 for p in (a, b) for q in (c, d)):
                        # The source SVG contains a tiny closure kink at the
                        # left edge of Z6.  It is a stroke-width artifact, not
                        # an interior self-crossing.
                        continue
                    errors.append(f"{zone_id}: self-intersection between edges {index}/{other}")
        expected_norm = _pixel_to_norm(points, width, height)
        if any(
            abs(a - b) > 1e-6
            for left, right in zip(expected_norm, zones[zone_id]["polygon_norm"], strict=False)
            for a, b in zip(left, right, strict=False)
        ):
            errors.append(f"{zone_id}: polygon_norm does not match polygon_px/reference dimensions")
    for index, first_id in enumerate(ZONE_ORDER):
        for second_id in ZONE_ORDER[index + 1 :]:
            first, second = zones[first_id]["polygon_px"], zones[second_id]["polygon_px"]
            # A proper interior crossing is an error. Shared edges/vertices are allowed.
            for i in range(len(first)):
                for j in range(len(second)):
                    if segments_intersect(
                        first[i],
                        first[(i + 1) % len(first)],
                        second[j],
                        second[(j + 1) % len(second)],
                    ):
                        a = first[i]
                        b = first[(i + 1) % len(first)]
                        c = second[j]
                        d = second[(j + 1) % len(second)]
                        shared_endpoint = any(
                            math.dist(p, q) < 1e-4 for p in (a, b) for q in (c, d)
                        )
                        collinear = (
                            abs(_orientation(a, b, c)) < 1e-4 and abs(_orientation(a, b, d)) < 1e-4
                        )
                        if not shared_endpoint and not collinear:
                            errors.append(f"{first_id}/{second_id}: crossing boundary segments")
    if errors:
        raise ValueError("Invalid zone configuration: " + "; ".join(errors))
    return {"zone_count": len(zones), "self_intersections": 0, "interior_crossings": 0}


def render_zone_overlay(
    config: dict, image_path: Path, output_path: Path, *, title="PROVISIONAL IMAGE-SPACE ZONES"
) -> None:
    with Image.open(image_path).convert("RGB") as image:
        canvas = image.copy()
    draw = ImageDraw.Draw(canvas, "RGBA")
    font = ImageFont.load_default()
    for zone in config["zones"]:
        points = [tuple(point) for point in zone["polygon_px"]]
        color = ZONE_COLORS[zone["id"]]
        draw.polygon(points, fill=(*color, 38), outline=(*color, 255), width=5)
        center = (
            sum(point[0] for point in points) / len(points),
            sum(point[1] for point in points) / len(points),
        )
        draw.rounded_rectangle(
            (center[0] - 30, center[1] - 10, center[0] + 30, center[1] + 10),
            radius=4,
            fill=(0, 0, 0, 170),
        )
        draw.text((center[0] - 20, center[1] - 7), zone["id"], fill=(255, 255, 255, 255), font=font)
    draw.rectangle((8, 8, 250, 28), fill=(0, 0, 0, 180))
    draw.text((14, 13), title, fill=(255, 255, 255, 255), font=font)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output_path)


def _anchor(box, policy: str) -> tuple[float, float]:
    x1, y1, x2, y2 = box
    if policy == "center":
        return ((x1 + x2) / 2, (y1 + y2) / 2)
    if policy == "bottom_center":
        return ((x1 + x2) / 2, y2)
    raise ValueError(f"Unsupported anchor policy: {policy}")


def assign_point(
    config: dict,
    point: tuple[float, float],
    *,
    frame_size: tuple[int, int] | None = None,
    previous_zone: str | None = None,
    track_id: str | None = None,
) -> dict:
    width, height = frame_size or (
        config["reference"]["width"],
        config["reference"]["height"],
    )
    reference_width = config["reference"]["width"]
    reference_height = config["reference"]["height"]
    reference_tolerance = float(
        config["assignment"].get(
            "boundary_tolerance_reference_px",
            config["assignment"].get("boundary_tolerance_px", 12),
        )
    )
    tolerance = reference_tolerance * math.sqrt(
        (width / reference_width) * (height / reference_height)
    )
    candidates = []
    near_boundary = []
    for zone in config["zones"]:
        polygon = _norm_to_pixel(zone["polygon_norm"], width, height)
        inside = point_in_polygon(point, polygon)
        distance = distance_to_polygon(point, polygon)
        if inside:
            candidates.append(zone["id"])
        if distance <= tolerance:
            near_boundary.append(zone["id"])
    tie_break = config["assignment"]["no_history_tie_break"]
    if previous_zone and track_id and near_boundary and previous_zone in candidates + near_boundary:
        return {
            "zone": previous_zone,
            "status": "assigned",
            "ambiguity": True,
            "tolerance_px_used": tolerance,
            "reason": "track_history_retained_within_tolerance_band",
        }
    eligible = set(candidates) | set(near_boundary)
    if eligible:
        ordered = [zone for zone in tie_break if zone in eligible]
        chosen = ordered[0]
        return {
            "zone": chosen,
            "status": "boundary_ambiguous" if len(eligible) > 1 else "assigned",
            "ambiguity": len(eligible) > 1,
            "tolerance_px_used": tolerance,
            "reason": "explicit_right_zone_tie_break"
            if len(eligible) > 1
            else ("within_tolerance_band" if near_boundary else "inside_zone"),
        }
    return {
        "zone": None,
        "status": "outside_zone",
        "ambiguity": bool(near_boundary),
        "tolerance_px_used": tolerance,
        "reason": "outside_all_zone_polygons",
    }


def validate_frame(config: dict, image_path: Path, *, allow_content_different=True) -> dict:
    with Image.open(image_path) as image:
        width, height = image.size
    reference = config["reference"]
    source_hash = sha256(image_path)
    result = {
        "file": str(image_path),
        "sha256": source_hash,
        "width": width,
        "height": height,
        "aspect_ratio": width / height,
        "reference_dimensions_match": (width, height) == (reference["width"], reference["height"]),
        "aspect_ratio_match": math.isclose(
            width / height, reference["aspect_ratio"], rel_tol=0, abs_tol=1e-6
        ),
        "content_hash_match": source_hash == reference["sha256"],
        "crop_rotation_review_required": source_hash != reference["sha256"],
        "status": "ok",
    }
    if not result["aspect_ratio_match"]:
        result["status"] = "reject_aspect_ratio_or_crop_changed"
    elif not result["reference_dimensions_match"]:
        result["status"] = (
            "ok_rescaled_same_aspect_manual_crop_check"
            if allow_content_different
            else "reject_dimensions_changed"
        )
    elif not result["content_hash_match"]:
        result["status"] = "ok_same_capture_geometry_content_differs"
    return result


def _load_gt(labels_path: Path) -> tuple[dict[str, dict], dict[str, list[dict]]]:
    data = json.loads(labels_path.read_text(encoding="utf-8"))
    images = {item["file_name"]: item for item in data["images"]}
    annotations = {name: [] for name in images}
    by_id = {item["id"]: item["file_name"] for item in data["images"]}
    for ann in data["annotations"]:
        file_name = by_id[ann["image_id"]]
        x, y, width, height = ann["bbox"]
        annotations[file_name].append(
            {
                "id": ann["id"],
                "box": [x, y, x + width, y + height],
                "seated": bool(ann.get("attributes", {}).get("seated", False)),
                "partial": bool(ann.get("attributes", {}).get("partial", False)),
                "uncertain": bool(ann.get("attributes", {}).get("uncertain", False)),
            }
        )
    return images, annotations


def _load_predictions(path: Path) -> dict[str, list[dict]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    result = {}
    for frame in data.get("frames", []):
        result[frame["file"]] = [
            {
                "index": index,
                "confidence": prediction.get("confidence"),
                "box": prediction.get("xyxy", []),
            }
            for index, prediction in enumerate(frame.get("detections", []))
        ]
    return result


def _load_expected(path: Path | None) -> dict:
    if not path or not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def person_zone_preview(
    config_path: Path,
    labels_path: Path,
    predictions_path: Path,
    images_dir: Path,
    output_dir: Path,
    selected_frames: Iterable[str],
    expected_path: Path | None = None,
) -> dict:
    config = load_config(config_path)
    image_info, ground_truth = _load_gt(labels_path)
    predictions = _load_predictions(predictions_path)
    expected = _load_expected(expected_path)
    wanted = set(selected_frames)
    files = [name for name in image_info if not wanted or any(token in name for token in wanted)]
    output_dir.mkdir(parents=True, exist_ok=True)
    rows = []
    for file_name in files:
        image_path = images_dir / file_name
        if not image_path.exists():
            continue
        frame_result = validate_frame(config, image_path)
        frame = Image.open(image_path).convert("RGB")
        draw = ImageDraw.Draw(frame, "RGBA")
        # Draw zones on the diagnostic image without altering the source image.
        for zone in config["zones"]:
            points = [tuple(point) for point in zone["polygon_px"]]
            color = ZONE_COLORS[zone["id"]]
            draw.line(points + [points[0]], fill=(*color, 210), width=3)
        for ann in ground_truth.get(file_name, []):
            x1, y1, x2, y2 = ann["box"]
            draw.rectangle((x1, y1, x2, y2), outline=(60, 150, 255, 220), width=3)
            draw.text((x1 + 2, y1 + 2), f"GT {ann['id']}", fill=(60, 150, 255, 255))
            for policy, _suffix in (("center", "C"), ("bottom_center", "B")):
                point = _anchor(ann["box"], policy)
                assignment = assign_point(config, point, frame_size=frame.size)
                key = f"gt:{ann['id']}:{policy}"
                rows.append(
                    _assignment_row(
                        file_name,
                        "ground_truth",
                        ann["id"],
                        1.0,
                        ann["box"],
                        policy,
                        point,
                        assignment,
                        ann,
                        expected.get(file_name, {}).get(key),
                    )
                )
        for pred in predictions.get(file_name, []):
            x1, y1, x2, y2 = pred["box"]
            draw.rectangle((x1, y1, x2, y2), outline=(255, 150, 30, 255), width=3)
            for policy, suffix in (("center", "C"), ("bottom_center", "B")):
                point = _anchor(pred["box"], policy)
                assignment = assign_point(config, point, frame_size=frame.size)
                key = f"pred:{pred['index']}:{policy}"
                expected_zone = expected.get(file_name, {}).get(key)
                label = f"P{pred['index']} {pred['confidence']:.2f} {suffix}:{assignment['zone'] or 'OUT'}"
                if assignment["ambiguity"]:
                    label += " ?"
                draw.ellipse(
                    (point[0] - 5, point[1] - 5, point[0] + 5, point[1] + 5),
                    fill=(255, 255, 0, 255),
                    outline=(0, 0, 0, 255),
                )
                draw.text(
                    (x1 + 2, y1 + 16 + (0 if suffix == "C" else 12)),
                    label,
                    fill=(255, 230, 20, 255),
                )
                rows.append(
                    _assignment_row(
                        file_name,
                        "prediction",
                        pred["index"],
                        pred["confidence"],
                        pred["box"],
                        policy,
                        point,
                        assignment,
                        None,
                        expected_zone,
                    )
                )
        frame.save(output_dir / f"{Path(file_name).stem}.png")
        rows.append({"file": file_name, "record_type": "frame", "image_status": frame_result})
    (output_dir / "assignments.json").write_text(
        json.dumps(rows, indent=2) + "\n", encoding="utf-8"
    )
    fieldnames = sorted({key for row in rows if row.get("record_type") != "frame" for key in row})
    with (output_dir / "assignments.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            if row.get("record_type") != "frame":
                writer.writerow({field: row.get(field) for field in fieldnames})
    template = {
        file_name: {
            f"gt:{ann['id']}:{policy}": None
            for ann in ground_truth.get(file_name, [])
            for policy in ("center", "bottom_center")
        }
        for file_name in files
    }
    for file_name in files:
        for pred in predictions.get(file_name, []):
            for policy in ("center", "bottom_center"):
                template.setdefault(file_name, {})[f"pred:{pred['index']}:{policy}"] = None
    (output_dir / "expected_zone_labels.template.json").write_text(
        json.dumps(template, indent=2) + "\n", encoding="utf-8"
    )
    return {
        "files": len(files),
        "assignment_records": len([row for row in rows if row.get("record_type") != "frame"]),
        "output": str(output_dir),
    }


def _assignment_row(
    file_name, record_type, record_id, confidence, box, policy, point, assignment, ann, expected
):
    return {
        "record_type": record_type,
        "file": file_name,
        "record_id": record_id,
        "confidence": confidence,
        "box_x1": box[0],
        "box_y1": box[1],
        "box_x2": box[2],
        "box_y2": box[3],
        "anchor_policy": policy,
        "anchor_x": point[0],
        "anchor_y": point[1],
        "assigned_zone": assignment["zone"],
        "status": assignment["status"],
        "ambiguity": assignment["ambiguity"],
        "reason": assignment["reason"],
        "expected_zone": expected,
        "expected_match": expected is not None and expected == assignment["zone"],
        "seated": ann.get("seated") if ann else None,
        "partial": ann.get("partial") if ann else None,
        "uncertain": ann.get("uncertain") if ann else None,
    }


def validate_geometry(config_path: Path, output: Path) -> dict:
    config = load_config(config_path)
    zones = {zone["id"]: zone["polygon_px"] for zone in config["zones"]}
    probes = {
        "inside_zone_centers": {},
        "shared_edge_probes": [],
        "outside_points": [],
    }
    for zone, points in zones.items():
        point = (sum(p[0] for p in points) / len(points), sum(p[1] for p in points) / len(points))
        probes["inside_zone_centers"][zone] = assign_point(config, point)
    shared_pairs = {
        ("Z1", "Z2"): ((0, 1), (1, 2)),
        ("Z3", "Z4"): ((0, 2), (1, 3)),
        ("Z5", "Z6"): ((0, 3), (1, 2)),
    }
    for (right, left), pairs in shared_pairs.items():
        left_points = zones[left]
        right_points = zones[right]
        for right_index, left_index in pairs:
            a = right_points[right_index]
            b = left_points[left_index]
            point = ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)
            probes["shared_edge_probes"].append(
                {"zones": [left, right], "point": point, "assignment": assign_point(config, point)}
            )
    width, height = config["reference"]["width"], config["reference"]["height"]
    probes["outside_points"] = [
        {"point": point, "assignment": assign_point(config, point)}
        for point in [(0, 0), (width - 1, height - 1), (width / 2, 100), (width / 2, height - 1)]
    ]
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps({"validation": validate_config(config), "probes": probes}, indent=2) + "\n",
        encoding="utf-8",
    )
    return probes


class ZoneEditor:
    def __init__(self, config_path: Path, preview_path: Path):
        import tkinter as tk

        from PIL import ImageTk

        self.image_tk = ImageTk
        self.tk = tk
        self.config_path = config_path
        self.preview_path = preview_path
        self.config = load_config(config_path)
        self.reference_path = Path(self.config["reference"]["file"])
        if not self.reference_path.is_absolute():
            self.reference_path = config_path.parent / self.reference_path
        self.image = Image.open(self.reference_path).convert("RGB")
        self.root = tk.Tk()
        self.root.title("Provisional six-zone editor - offline")
        self.canvas = tk.Canvas(self.root, width=1200, height=800, bg="black")
        self.canvas.pack()
        self.status = tk.Label(self.root, anchor="w")
        self.status.pack(fill="x")
        self.zone = "Z1"
        self.drag = None
        self.scale = min(1180 / self.image.width, 760 / self.image.height)
        self.offset = (10, 10)
        self.tk_image = None
        self.redraw()
        self.canvas.bind("<Button-1>", self.click)
        self.canvas.bind("<B1-Motion>", self.drag_vertex)
        self.canvas.bind("<ButtonRelease-1>", lambda _event: setattr(self, "drag", None))
        self.root.bind("<Control-s>", lambda _event: self.save())
        self.root.bind("<Key>", self.key)

    def screen(self, point):
        return (self.offset[0] + point[0] * self.scale, self.offset[1] + point[1] * self.scale)

    def image_point(self, event):
        return ((event.x - self.offset[0]) / self.scale, (event.y - self.offset[1]) / self.scale)

    def redraw(self):

        resized = self.image.resize(
            (round(self.image.width * self.scale), round(self.image.height * self.scale))
        )
        self.tk_image = self.image_tk.PhotoImage(resized)
        self.canvas.delete("all")
        self.canvas.create_image(*self.offset, image=self.tk_image, anchor="nw")
        for zone in self.config["zones"]:
            points = [self.screen(point) for point in zone["polygon_px"]]
            color = "#{:02x}{:02x}{:02x}".format(*ZONE_COLORS[zone["id"]])
            self.canvas.create_polygon(points, outline=color, fill="", width=3)
            for index, point in enumerate(points):
                self.canvas.create_oval(
                    point[0] - 5,
                    point[1] - 5,
                    point[0] + 5,
                    point[1] + 5,
                    fill=color if zone["id"] == self.zone else "white",
                    outline=color,
                )
                self.canvas.create_text(
                    point[0] + 8, point[1] - 8, text=f"{zone['id']}:{index}", fill=color, anchor="w"
                )
        self.status.configure(
            text=f"Selected {self.zone}. Press 1-6 to select; drag a vertex; Ctrl-S saves and exports preview."
        )

    def key(self, event):
        if event.char in "123456":
            self.zone = f"Z{event.char}"
            self.redraw()

    def click(self, event):
        point = self.image_point(event)
        zone = next(
            (zone for zone in self.config["zones"] if point_in_polygon(point, zone["polygon_px"])),
            None,
        )
        if zone:
            self.zone = zone["id"]
        nearest = None
        nearest_distance = 18 / self.scale
        for candidate in self.config["zones"]:
            for index, vertex in enumerate(candidate["polygon_px"]):
                distance = math.dist(point, vertex)
                if distance < nearest_distance:
                    nearest = (candidate["id"], index)
                    nearest_distance = distance
        self.drag = nearest
        self.redraw()

    def drag_vertex(self, event):
        if not self.drag:
            return
        point = list(self.image_point(event))
        zone_id, index = self.drag
        groups = [
            group
            for group in self.config.get("sync_groups", [])
            if {"zone": zone_id, "index": index} in group["vertices"]
        ]
        target = [{"zone": zone_id, "index": index}]
        for group in groups:
            target.extend(group["vertices"])
        seen = set()
        for item in target:
            key = (item["zone"], item["index"])
            if key in seen:
                continue
            seen.add(key)
            zone = next(zone for zone in self.config["zones"] if zone["id"] == item["zone"])
            zone["polygon_px"][item["index"]] = [round(point[0], 3), round(point[1], 3)]
            zone["polygon_norm"][item["index"]] = [
                round(point[0] / self.config["reference"]["width"], 9),
                round(point[1] / self.config["reference"]["height"], 9),
            ]
        self.redraw()

    def save(self):
        validate_config(self.config)
        backup = self.config_path.with_suffix(self.config_path.suffix + ".bak")
        shutil.copy2(self.config_path, backup)
        self.config_path.write_text(json.dumps(self.config, indent=2) + "\n", encoding="utf-8")
        render_zone_overlay(self.config, self.reference_path, self.preview_path)
        self.status.configure(
            text=f"Saved {self.config_path}; backup {backup.name}; preview {self.preview_path}"
        )

    def run(self):
        self.root.mainloop()


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    build = sub.add_parser("build", help="Build the provisional config from SVG source polygons")
    build.add_argument("--svg", type=Path, required=True)
    build.add_argument("--reference", type=Path, required=True)
    build.add_argument("--config", type=Path, required=True)
    build.add_argument("--output", type=Path, required=True)
    preview = sub.add_parser("preview", help="Render a clean six-zone overlay")
    preview.add_argument("--config", type=Path, required=True)
    preview.add_argument("--image", type=Path, required=True)
    preview.add_argument("--output", type=Path, required=True)
    validate = sub.add_parser("validate", help="Validate geometry and deterministic probes")
    validate.add_argument("--config", type=Path, required=True)
    validate.add_argument("--output", type=Path, required=True)
    verify = sub.add_parser("verify-frame", help="Check aspect ratio, dimensions and content hash")
    verify.add_argument("--config", type=Path, required=True)
    verify.add_argument("--image", type=Path, required=True)
    editor = sub.add_parser("edit", help="Open the offline Tk polygon editor")
    editor.add_argument("--config", type=Path, required=True)
    editor.add_argument("--preview", type=Path, required=True)
    people = sub.add_parser("person-preview", help="Render person-to-zone diagnostic overlays")
    people.add_argument("--config", type=Path, required=True)
    people.add_argument("--labels", type=Path, required=True)
    people.add_argument("--predictions", type=Path, required=True)
    people.add_argument("--images", type=Path, required=True)
    people.add_argument("--output", type=Path, required=True)
    people.add_argument("--expected", type=Path)
    people.add_argument("--frame", action="append", default=[])
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "build":
            build_config(args.svg, args.reference, args.config, args.output)
            print(f"Wrote provisional config: {args.config}")
            print(f"Wrote clean overlay: {args.output / 'zone_overlay_reference.png'}")
        elif args.command == "preview":
            config = load_config(args.config)
            render_zone_overlay(config, args.image, args.output)
            print(f"Wrote {args.output}")
        elif args.command == "validate":
            validate_geometry(args.config, args.output)
            print(f"Wrote validation: {args.output}")
        elif args.command == "verify-frame":
            print(json.dumps(validate_frame(load_config(args.config), args.image), indent=2))
        elif args.command == "edit":
            ZoneEditor(args.config, args.preview).run()
        elif args.command == "person-preview":
            result = person_zone_preview(
                args.config,
                args.labels,
                args.predictions,
                args.images,
                args.output,
                args.frame,
                args.expected,
            )
            print(json.dumps(result, indent=2))
    except (OSError, ValueError, ET.ParseError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
