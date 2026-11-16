"""Offline review tools for the provisional six-zone image-space draft.

This module never writes the source artwork, COCO annotations, production
configuration, MQTT state, model files, or hardware.  A proposal is kept in
its own JSON document and is explicitly marked as needing human review.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import sys
from collections import Counter, defaultdict
from collections.abc import Sequence
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

from .zone_definition import (
    ZONE_COLORS,
    ZONE_ORDER,
    _anchor,
    assign_point,
    load_config,
    render_zone_overlay,
    sha256,
    validate_config,
)

PROPOSAL_DIVIDER = [[900.0, 659.0], [880.0, 713.0], [830.0, 875.0], [810.0, 1313.0]]
PROPOSAL_AISLE_RIGHT = {"far": 1070.0, "middle": 1100.0, "near": 1160.0}
REVIEW_LABELS = set(ZONE_ORDER) | {"outside_monitored_area", "uncertain"}


def _copy_point(point):
    return [round(float(point[0]), 3), round(float(point[1]), 3)]


def _norm(points, width, height):
    return [[round(float(x) / width, 9), round(float(y) / height, 9)] for x, y in points]


def _source_zone_map(config):
    return {zone["id"]: zone for zone in config["zones"]}


def _clip_polygon(points, width, height):
    """Clip only for diagnostic rendering/measurement; source points stay intact."""

    def clip_against(vertices, inside, intersection):
        if not vertices:
            return []
        result = []
        previous = vertices[-1]
        previous_inside = inside(previous)
        for current in vertices:
            current_inside = inside(current)
            if current_inside != previous_inside:
                result.append(intersection(previous, current))
            if current_inside:
                result.append(current)
            previous, previous_inside = current, current_inside
        return result

    def horizontal(y, upper):
        def inside(point):
            return point[1] >= y if upper else point[1] <= y

        def intersection(a, b):
            if b[1] == a[1]:
                return [a[0], y]
            t = (y - a[1]) / (b[1] - a[1])
            return [a[0] + t * (b[0] - a[0]), y]

        return inside, intersection

    def vertical(x, left):
        def inside(point):
            return point[0] >= x if left else point[0] <= x

        def intersection(a, b):
            if b[0] == a[0]:
                return [x, a[1]]
            t = (x - a[0]) / (b[0] - a[0])
            return [x, a[1] + t * (b[1] - a[1])]

        return inside, intersection

    result = [list(point) for point in points]
    for boundary in (
        horizontal(0, True),
        horizontal(height, False),
        vertical(0, True),
        vertical(width, False),
    ):
        result = clip_against(result, *boundary)
    return [[round(x, 3), round(y, 3)] for x, y in result]


def _raster_metrics(outer, zones, width, height, scale=4):
    raster_width = math.ceil(width / scale)
    raster_height = math.ceil(height / scale)

    def mask(points):
        image = Image.new("L", (raster_width, raster_height), 0)
        ImageDraw.Draw(image).polygon([(x / scale, y / scale) for x, y in points], fill=1)
        return image.tobytes()

    outer_bytes = mask(outer)
    zone_images = {}
    zone_bytes = {}
    for zone, points in zones.items():
        image = Image.new("L", (raster_width, raster_height), 0)
        ImageDraw.Draw(image).polygon([(x / scale, y / scale) for x, y in points], fill=1)
        zone_images[zone] = image
        zone_bytes[zone] = image.tobytes()
    interior_bytes = {
        zone: image.filter(ImageFilter.MinFilter(3)).tobytes()
        for zone, image in zone_images.items()
    }
    uncovered = overlap = interior_overlap = 0
    pairwise = Counter()
    interior_pairwise = Counter()
    for index, outer_value in enumerate(outer_bytes):
        if not outer_value:
            continue
        covered = [zone for zone, values in zone_bytes.items() if values[index]]
        if not covered:
            uncovered += 1
        if len(covered) > 1:
            overlap += 1
            for left_index, first in enumerate(covered):
                for second in covered[left_index + 1 :]:
                    pairwise[f"{first}/{second}"] += 1
        interior_covered = [zone for zone, values in interior_bytes.items() if values[index]]
        if len(interior_covered) > 1:
            interior_overlap += 1
            for left_index, first in enumerate(interior_covered):
                for second in interior_covered[left_index + 1 :]:
                    interior_pairwise[f"{first}/{second}"] += 1
    pixel_area = scale * scale
    return {
        "raster_scale": scale,
        "outer_area_px2_approx": sum(bool(value) for value in outer_bytes) * pixel_area,
        "uncovered_area_px2_approx": uncovered * pixel_area,
        "boundary_inclusive_overlap_area_px2_approx": overlap * pixel_area,
        "pairwise_overlap_area_px2_approx": {
            key: value * pixel_area for key, value in sorted(pairwise.items())
        },
        "interior_overlap_area_px2_approx": interior_overlap * pixel_area,
        "interior_pairwise_overlap_area_px2_approx": {
            key: value * pixel_area for key, value in sorted(interior_pairwise.items())
        },
    }


def _divider_interpolate(divider, y):
    for first, second in zip(divider, divider[1:], strict=False):
        if min(first[1], second[1]) <= y <= max(first[1], second[1]):
            if second[1] == first[1]:
                return first[0]
            fraction = (y - first[1]) / (second[1] - first[1])
            return first[0] + fraction * (second[0] - first[0])
    return divider[0][0] if y < divider[0][1] else divider[-1][0]


def _proposal_vertices(width, height, divider=None):
    divider = divider or PROPOSAL_DIVIDER
    # These points are copied from the source-derived outer edges.  The two
    # points outside x=[0, width] are intentionally retained.
    left_top = [557.26, 669.26]
    left_b1 = [466.36, 721.68]
    left_b2 = [253.94, 873.79]
    left_outside = [-86.97, 1169.24]
    left_bottom = [384.24, 1288.94]
    right_top = [1324.57, 660.06]
    right_b1 = [1444.4, 707.72]
    right_b2 = [1678.18, 846.52]
    right_mid = [2028.18, 1108.64]
    right_bottom = [1560.0, 1238.94]
    boundaries = {
        "far_top": [left_top, divider[0], right_top],
        "far_middle": [left_b1, divider[1], right_b1],
        "middle_near": [left_b2, divider[2], right_b2],
        "near_bottom": [left_bottom, divider[3], right_bottom],
    }
    zones = {
        "Z6": [left_top, divider[0], divider[1], left_b1],
        "Z5": [divider[0], right_top, right_b1, divider[1]],
        "Z4": [left_b1, divider[1], divider[2], left_b2],
        "Z3": [divider[1], right_b1, right_b2, divider[2]],
        "Z2": [left_b2, divider[2], divider[3], left_bottom, left_outside],
        "Z1": [divider[2], right_b2, right_mid, right_bottom, divider[3]],
    }
    outer = [
        left_top,
        right_top,
        right_b1,
        right_b2,
        right_mid,
        right_bottom,
        left_bottom,
        left_outside,
        left_b2,
        left_b1,
    ]
    return {"divider": divider, "boundaries": boundaries, "zones": zones, "outer": outer}


def _sync_groups(vertices):
    """Return vertex groups for every shared edge endpoint."""
    groups = []
    # Build groups from equal coordinate occurrences.  A point at a junction
    # is intentionally placed in one group containing every incident cell.
    all_points = defaultdict(list)
    for zone, points in vertices.items():
        for index, point in enumerate(points):
            all_points[tuple(point)].append({"zone": zone, "index": index})
    for _point, occurrences in all_points.items():
        if len(occurrences) > 1:
            groups.append({"id": f"shared_vertex_{len(groups)}", "vertices": occurrences})
    return groups


def build_aisle_proposal(base_path: Path, output_path: Path, artifact_dir: Path, divider=None):
    base = load_config(base_path)
    width, height = base["reference"]["width"], base["reference"]["height"]
    geometry = _proposal_vertices(width, height, divider)
    source_zones = _source_zone_map(base)
    zones = []
    for zone_id in ZONE_ORDER:
        points = geometry["zones"][zone_id]
        source = source_zones[zone_id]
        zones.append(
            {
                "id": zone_id,
                "band": source["band"],
                "side": source["side"],
                "appliance": source["appliance"],
                "source_polygon_px": source["polygon_px"],
                "polygon_px": [_copy_point(point) for point in points],
                "polygon_norm": _norm(points, width, height),
                "diagnostic_clipped_polygon_px": _clip_polygon(points, width, height),
                "source_polygon_index": source["source_polygon_index"],
            }
        )
    outer = geometry["outer"]
    proposal = dict(base)
    proposal.update(
        {
            "schema": "image_zone_definition_proposal",
            "schema_version": 2,
            "status": "provisional_aisle_edge_proposal_needs_review",
            "zones": zones,
            "monitored_outer_region": {
                "name": "desktop_envelope_source_outer_edges",
                "polygon_px": [_copy_point(point) for point in outer],
                "polygon_norm": _norm(outer, width, height),
                "diagnostic_clipped_polygon_px": _clip_polygon(outer, width, height),
                "outside_image_vertices_preserved": True,
            },
            "proposal": {
                "approved": False,
                "review_required": True,
                "proposal_type": "image_left_edge_of_central_aisle",
                "divider_proposal_px": geometry["divider"],
                "old_divider_description": (
                    "source-derived shared edge around x=950-970; retained in the base config"
                ),
                "proposal_uncertainty_band_px_at_reference": 40,
                "aisle_right_edge_test_only": PROPOSAL_AISLE_RIGHT,
                "notes": [
                    "The proposed divider is an editable visual hypothesis, not user approval.",
                    (
                        "It follows the visible image-left aisle edge by inspection and "
                        "must be reviewed."
                    ),
                    (
                        "The right edge values are test-only extents; they do not redefine "
                        "the zone boundary."
                    ),
                ],
            },
            "shared_edges": [
                {"id": key, "points_px": [_copy_point(point) for point in points]}
                for key, points in geometry["boundaries"].items()
            ]
            + [
                {"id": "divider_far", "points_px": geometry["divider"][0:2]},
                {"id": "divider_middle", "points_px": geometry["divider"][1:3]},
                {"id": "divider_near", "points_px": geometry["divider"][2:4]},
            ],
            "sync_groups": _sync_groups(geometry["zones"]),
            "source_preservation": {
                "base_config": str(base_path),
                "base_config_sha256": sha256(base_path),
                "source_polygons_preserved_in_each_zone": True,
                "clipping_is_diagnostic_only": True,
            },
        }
    )
    validate_config(proposal)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(proposal, indent=2) + "\n", encoding="utf-8")
    artifact_dir.mkdir(parents=True, exist_ok=True)
    render_zone_overlay(
        proposal,
        Path(base_path).parent / base["reference"]["file"],
        artifact_dir / "zone_overlay_aisle_proposal.png",
    )
    render_boundary_comparison(
        base,
        proposal,
        Path(base_path).parent / base["reference"]["file"],
        artifact_dir / "aisle_boundary_old_vs_proposed.png",
    )
    validation = validate_proposal(base, proposal)
    (artifact_dir / "aisle_proposal_validation.json").write_text(
        json.dumps(validation, indent=2) + "\n", encoding="utf-8"
    )
    return proposal, validation


def render_boundary_comparison(old_config, proposed_config, image_path: Path, output_path: Path):
    image = Image.open(image_path).convert("RGB")
    draw = ImageDraw.Draw(image, "RGBA")
    font = ImageFont.load_default()
    old_zones = _source_zone_map(old_config)
    for zone_id in ZONE_ORDER:
        points = [tuple(point) for point in old_zones[zone_id]["polygon_px"]]
        draw.line(points + [points[0]], fill=(255, 255, 255, 210), width=3)
    for zone in proposed_config["zones"]:
        points = [tuple(point) for point in zone["polygon_px"]]
        color = ZONE_COLORS[zone["id"]]
        draw.line(points + [points[0]], fill=(*color, 205), width=5)
    old_dividers = (("Z2", 1, 2), ("Z4", 2, 3), ("Z6", 2, 3))
    for zone_id, first, second in old_dividers:
        points = old_zones[zone_id]["polygon_px"]
        draw.line((tuple(points[first]), tuple(points[second])), fill=(255, 255, 0, 255), width=5)
    divider = proposed_config["proposal"]["divider_proposal_px"]
    draw.line([tuple(point) for point in divider], fill=(255, 30, 30, 255), width=7)
    for index, point in enumerate(divider):
        draw.ellipse(
            (point[0] - 8, point[1] - 8, point[0] + 8, point[1] + 8), fill=(255, 30, 30, 255)
        )
        draw.text(
            (point[0] + 10, point[1] - 10),
            f"P{index} {point[0]:.0f},{point[1]:.0f}",
            fill=(255, 30, 30, 255),
            font=font,
        )
    draw.rectangle((8, 8, 410, 42), fill=(0, 0, 0, 190))
    draw.text(
        (14, 14), "WHITE=old zone edges  YELLOW=old divider  RED=proposal", fill="white", font=font
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    image.save(output_path)


def build_aisle_test_points(proposal):
    divider = proposal["proposal"]["divider_proposal_px"]
    profiles = [("far", 680, 0, 1), ("middle", 790, 1, 2), ("near", 1050, 2, 3)]
    result = []
    for band, y, first, second in profiles:
        left = _divider_interpolate([divider[first], divider[second]], y)
        right = proposal["proposal"]["aisle_right_edge_test_only"][band]
        expected = {"far": "Z5", "middle": "Z3", "near": "Z1"}[band]
        for fraction in (0.0, 0.25, 0.5, 0.75, 1.0):
            point = [round(left + fraction * (right - left), 3), float(y)]
            result.append(
                {
                    "band": band,
                    "fraction_across_aisle": fraction,
                    "point": point,
                    "expected_right_zone": expected,
                    "assignment": assign_point(proposal, tuple(point)),
                }
            )
    return result


def validate_proposal(base, proposal):
    width, height = proposal["reference"]["width"], proposal["reference"]["height"]
    zones = {zone["id"]: zone["polygon_px"] for zone in proposal["zones"]}
    test_points = build_aisle_test_points(proposal)
    for row in test_points:
        row["old_assignment"] = assign_point(base, tuple(row["point"]))
        row["proposal_pass"] = row["assignment"]["zone"] == row["expected_right_zone"]
    geometry = validate_config(proposal)
    metrics = _raster_metrics(
        proposal["monitored_outer_region"]["polygon_px"], zones, width, height
    )
    source_outside = {
        zone["id"]: [
            point
            for point in zone["source_polygon_px"]
            if not (0 <= point[0] <= width and 0 <= point[1] <= height)
        ]
        for zone in proposal["zones"]
    }
    return {
        "status": "provisional_needs_visual_review",
        "geometry": geometry,
        "monitored_outer_region": {
            "vertices_px": proposal["monitored_outer_region"]["polygon_px"],
            "clipped_vertices_px": proposal["monitored_outer_region"][
                "diagnostic_clipped_polygon_px"
            ],
            "source_outside_image_vertices_by_zone": source_outside,
        },
        "partition_metrics": metrics,
        "aisle_test_points": test_points,
        "all_aisle_test_points_right_owned": all(row["proposal_pass"] for row in test_points),
        "old_divider_is_not_whole_aisle_test_pass": all(
            row["old_assignment"]["zone"] == row["expected_right_zone"] for row in test_points
        ),
    }


def _load_ground_truth(labels_path: Path):
    data = json.loads(labels_path.read_text(encoding="utf-8"))
    images = {item["file_name"]: item for item in data["images"]}
    by_id = {item["id"]: item["file_name"] for item in data["images"]}
    annotations = defaultdict(list)
    for ann in data["annotations"]:
        x, y, width, height = ann["bbox"]
        annotations[by_id[ann["image_id"]]].append(
            {
                "id": ann["id"],
                "box": [x, y, x + width, y + height],
                "seated": bool(ann.get("attributes", {}).get("seated", False)),
                "partial": bool(ann.get("attributes", {}).get("partial", False)),
                "uncertain": bool(ann.get("attributes", {}).get("uncertain", False)),
            }
        )
    return images, annotations


def _priority_files(images):
    tokens = ("0023", "0035", "0036", "0102", "0151")
    return [name for name in images if any(token in name for token in tokens)]


def init_expected_review(labels_path: Path, output_path: Path, images=None):
    image_info, annotations = _load_ground_truth(labels_path)
    files = _priority_files(image_info) if images is None else list(images)
    entries = []
    for file_name in files:
        for ann in annotations[file_name]:
            entries.append(
                {
                    "file": file_name,
                    "annotation_id": ann["id"],
                    "box": ann["box"],
                    "seated": ann["seated"],
                    "partial": ann["partial"],
                    "uncertain_annotation_flag": ann["uncertain"],
                    "expected_zone": None,
                    "review_status": "unreviewed",
                }
            )
    document = {
        "schema": "manual_expected_zone_review",
        "diagnostic_only": True,
        "source_labels": str(labels_path),
        "source_labels_sha256": sha256(labels_path),
        "allowed_labels": sorted(REVIEW_LABELS),
        "entries": entries,
        "notes": [
            "This file is separate from the source COCO annotations.",
            "Null expected_zone entries are unreviewed and must not be counted as incorrect.",
        ],
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
    return document


class ExpectedZoneReviewer:
    def __init__(
        self,
        config_path: Path,
        labels_path: Path,
        images_dir: Path,
        review_path: Path,
        preview_dir: Path,
    ):
        import tkinter as tk

        from PIL import ImageTk

        self.tk = tk
        self.ImageTk = ImageTk
        self.config = load_config(config_path)
        self.images_dir = images_dir
        self.review_path = review_path
        self.preview_dir = preview_dir
        self.document = json.loads(review_path.read_text(encoding="utf-8"))
        self.entries = self.document["entries"]
        self.position = 0
        self.root = tk.Tk()
        self.root.title("Expected zone review - provisional, offline")
        self.canvas = tk.Canvas(self.root, width=1200, height=800, bg="black")
        self.canvas.pack()
        self.status = tk.Label(self.root, anchor="w", justify="left")
        self.status.pack(fill="x")
        buttons = tk.Frame(self.root)
        buttons.pack(fill="x")
        for label, value in [
            ("Z1", "Z1"),
            ("Z2", "Z2"),
            ("Z3", "Z3"),
            ("Z4", "Z4"),
            ("Z5", "Z5"),
            ("Z6", "Z6"),
            ("Outside", "outside_monitored_area"),
            ("Uncertain", "uncertain"),
        ]:
            tk.Button(buttons, text=label, command=lambda v=value: self.label(v)).pack(side="left")
        tk.Button(buttons, text="Previous", command=self.previous).pack(side="left")
        tk.Button(buttons, text="Next", command=self.next).pack(side="left")
        tk.Button(buttons, text="Save", command=self.save).pack(side="left")
        self.root.bind("<Key>", self.key)
        self.redraw()

    def key(self, event):
        values = {str(index): f"Z{index}" for index in range(1, 7)}
        values.update(
            {
                "o": "outside_monitored_area",
                "u": "uncertain",
                "n": "next",
                "p": "previous",
                "s": "save",
            }
        )
        value = values.get(event.char.lower())
        if value in REVIEW_LABELS:
            self.label(value)
        elif value == "next":
            self.next()
        elif value == "previous":
            self.previous()
        elif value == "save":
            self.save()

    def label(self, value):
        self.entries[self.position]["expected_zone"] = value
        self.entries[self.position]["review_status"] = "reviewed"
        self.save()
        self.next()

    def next(self):
        self.position = min(len(self.entries) - 1, self.position + 1)
        self.redraw()

    def previous(self):
        self.position = max(0, self.position - 1)
        self.redraw()

    def save(self):
        self.document["entries"] = self.entries
        self.review_path.write_text(json.dumps(self.document, indent=2) + "\n", encoding="utf-8")

    def redraw(self):
        entry = self.entries[self.position]
        image_path = self.images_dir / entry["file"]
        image = Image.open(image_path).convert("RGB")
        scale = min(1180 / image.width, 760 / image.height)
        resized = image.resize((round(image.width * scale), round(image.height * scale)))
        self.tk_image = self.ImageTk.PhotoImage(resized)
        self.canvas.delete("all")
        self.canvas.create_image(10, 10, image=self.tk_image, anchor="nw")
        draw = ImageDraw.Draw(image, "RGBA")
        # Draw the review image using a separate PIL image, preserving the source.
        for zone in self.config["zones"]:
            points = [tuple(point) for point in zone["polygon_px"]]
            draw.line(points + [points[0]], fill=(*ZONE_COLORS[zone["id"]], 220), width=4)
        annotations = _load_ground_truth_from_entries(self.entries, entry["file"])
        for other in annotations:
            box = other["box"]
            color = (
                (255, 30, 30, 255)
                if other["annotation_id"] == entry["annotation_id"]
                else (80, 170, 255, 230)
            )
            draw.rectangle(
                box,
                outline=color,
                width=6 if other["annotation_id"] == entry["annotation_id"] else 3,
            )
            draw.text((box[0] + 3, box[1] + 3), f"GT {other['annotation_id']}", fill=color)
        current = next(
            item for item in annotations if item["annotation_id"] == entry["annotation_id"]
        )
        center = assign_point(self.config, _anchor(current["box"], "center"))
        bottom = assign_point(self.config, _anchor(current["box"], "bottom_center"))
        for policy, assignment, color in (
            ("C", center, (255, 255, 0, 255)),
            ("B", bottom, (255, 150, 0, 255)),
        ):
            point = _anchor(current["box"], "center" if policy == "C" else "bottom_center")
            draw.ellipse(
                (point[0] - 7, point[1] - 7, point[0] + 7, point[1] + 7),
                fill=color,
                outline=(0, 0, 0, 255),
            )
            draw.text(
                (point[0] + 9, point[1] - 9),
                f"{policy}:{assignment['zone'] or 'OUT'}",
                fill=color,
            )
        label = (
            f"{entry['file']} | annotation {entry['annotation_id']} | "
            f"expected={entry.get('expected_zone') or 'UNREVIEWED'}\n"
        )
        label += (
            f"center={center['zone'] or 'OUT'} ({center['status']}) | "
            f"bottom-center={bottom['zone'] or 'OUT'} ({bottom['status']})"
        )
        self.status.configure(text=label)
        display = image.resize((round(image.width * scale), round(image.height * scale)))
        self.tk_image = self.ImageTk.PhotoImage(display)
        self.canvas.delete("all")
        self.canvas.create_image(10, 10, image=self.tk_image, anchor="nw")
        self.canvas.create_text(12, 12, text=label, fill="white", anchor="nw")

    def run(self):
        self.root.mainloop()


def _load_ground_truth_from_entries(entries, file_name):
    return [entry for entry in entries if entry["file"] == file_name]


def compare_expected_review(review_path: Path, assignments_path: Path, output_dir: Path):
    review = json.loads(review_path.read_text(encoding="utf-8"))
    entries = [
        entry
        for entry in review["entries"]
        if entry.get("review_status") == "reviewed" and entry.get("expected_zone")
    ]
    rows = list(csv.DictReader(assignments_path.open("r", newline="", encoding="utf-8")))
    by_key = {
        (row["file"], row["record_type"], row["record_id"], row["anchor_policy"]): row
        for row in rows
    }
    comparisons = []
    for entry in entries:
        expected = entry["expected_zone"]
        result = {
            "file": entry["file"],
            "annotation_id": str(entry["annotation_id"]),
            "expected_zone": expected,
            "seated": entry.get("seated", False),
            "partial": entry.get("partial", False),
            "center_assigned": None,
            "bottom_center_assigned": None,
            "center_correct": None,
            "bottom_center_correct": None,
        }
        for policy, field in (("center", "center"), ("bottom_center", "bottom_center")):
            row = by_key.get((entry["file"], "ground_truth", str(entry["annotation_id"]), policy))
            assigned = row.get("assigned_zone") or None if row else None
            result[f"{field}_assigned"] = assigned
            if expected in ZONE_ORDER:
                result[f"{field}_correct"] = assigned == expected
            elif expected == "outside_monitored_area":
                result[f"{field}_correct"] = assigned is None
            else:
                result[f"{field}_correct"] = None
        result["both_heuristics_fail"] = (
            expected in ZONE_ORDER
            and not result["center_correct"]
            and not result["bottom_center_correct"]
        )
        comparisons.append(result)
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "expected_zone_comparison.json").write_text(
        json.dumps(comparisons, indent=2) + "\n", encoding="utf-8"
    )
    fieldnames = list(comparisons[0]) if comparisons else ["file", "annotation_id", "expected_zone"]
    with (output_dir / "expected_zone_comparison.csv").open(
        "w", newline="", encoding="utf-8"
    ) as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(comparisons)
    report = _comparison_report(comparisons, len(entries), len(review["entries"]))
    (output_dir / "expected_zone_comparison_report.json").write_text(
        json.dumps(report, indent=2) + "\n", encoding="utf-8"
    )
    return report


def _comparison_report(rows, reviewed, total):
    report = {
        "reviewed_people": reviewed,
        "total_people": total,
        "unreviewed_people_not_counted": total - reviewed,
        "default_policy": "provisional; no heuristic selected automatically",
        "heuristics": {},
        "by_flag": {},
        "both_heuristics_fail": [
            {"file": row["file"], "annotation_id": row["annotation_id"]}
            for row in rows
            if row["both_heuristics_fail"]
        ],
    }
    for policy in ("center", "bottom_center"):
        relevant = [row for row in rows if row["expected_zone"] in ZONE_ORDER]
        correct = sum(bool(row[f"{policy}_correct"]) for row in relevant)
        outside_expected_inside = sum(row[f"{policy}_assigned"] is None for row in relevant)
        report["heuristics"][policy] = {
            "expected_inside_people": len(relevant),
            "correct": correct,
            "incorrect": len(relevant) - correct,
            "outside_zone_expected_inside": outside_expected_inside,
        }
        expected_outside = [row for row in rows if row["expected_zone"] == "outside_monitored_area"]
        report["heuristics"][policy]["expected_outside_people"] = len(expected_outside)
        report["heuristics"][policy]["outside_correct"] = sum(
            row[f"{policy}_assigned"] is None for row in expected_outside
        )
        report["heuristics"][policy]["outside_incorrect"] = sum(
            row[f"{policy}_assigned"] is not None for row in expected_outside
        )
        report["heuristics"][policy]["uncertain_people_excluded"] = sum(
            row["expected_zone"] == "uncertain" for row in rows
        )
    for flag in ("seated", "partial"):
        report["by_flag"][flag] = {}
        for policy in ("center", "bottom_center"):
            relevant = [row for row in rows if row[flag] and row["expected_zone"] in ZONE_ORDER]
            report["by_flag"][flag][policy] = {
                "people": len(relevant),
                "correct": sum(bool(row[f"{policy}_correct"]) for row in relevant),
                "incorrect": sum(not row[f"{policy}_correct"] for row in relevant),
                "outside_zone_expected_inside": sum(
                    row[f"{policy}_assigned"] is None for row in relevant
                ),
            }
    return report


def _parser():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    proposal = sub.add_parser("propose-aisle")
    proposal.add_argument("--base", type=Path, required=True)
    proposal.add_argument("--output", type=Path, required=True)
    proposal.add_argument("--artifacts", type=Path, required=True)
    review = sub.add_parser("manual-review")
    review.add_argument("--config", type=Path, required=True)
    review.add_argument("--labels", type=Path, required=True)
    review.add_argument("--images", type=Path, required=True)
    review.add_argument("--output", type=Path, required=True)
    review.add_argument("--init-only", action="store_true")
    compare = sub.add_parser("compare-review")
    compare.add_argument("--review", type=Path, required=True)
    compare.add_argument("--assignments", type=Path, required=True)
    compare.add_argument("--output", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "propose-aisle":
            _, validation = build_aisle_proposal(args.base, args.output, args.artifacts)
            print(json.dumps({"proposal": str(args.output), "validation": validation}, indent=2))
        elif args.command == "manual-review":
            if args.output.exists() and not args.init_only:
                document = json.loads(args.output.read_text(encoding="utf-8"))
            else:
                document = init_expected_review(args.labels, args.output)
            print(f"Prepared {len(document['entries'])} review entries: {args.output}")
            if not args.init_only:
                ExpectedZoneReviewer(
                    args.config, args.labels, args.images, args.output, args.output.parent
                ).run()
        elif args.command == "compare-review":
            report = compare_expected_review(args.review, args.assignments, args.output)
            print(json.dumps(report, indent=2))
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
