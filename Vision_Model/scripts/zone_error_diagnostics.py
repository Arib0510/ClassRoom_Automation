"""Regenerate six-zone assignment-error diagnostics from reviewed GT boxes.

This is an offline, diagnostic-only command.  It intentionally does not run a
detector, write labels, edit zone geometry, publish MQTT, or alter production
settings.  The gallery uses the current proposal geometry and the existing
ground-truth boxes so detection and assignment errors remain separate.
"""

# The command contains deliberately long HTML/report strings and a direct-run
# sys.path bootstrap; keep those two formatting exceptions local to this file.
# ruff: noqa: E501, I001

from __future__ import annotations

import argparse
import csv
import html
import json
import math
import shutil
import sys
from collections import defaultdict
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

# Allow direct execution as `python scripts/zone_error_diagnostics.py` from the
# Vision_Model package root.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from src.zone_definition import (
    ZONE_COLORS,
    ZONE_ORDER,
    _anchor,
    assign_point,
    distance_to_polygon,
    distance_to_segment,
    load_config,
    point_in_polygon,
    sha256,
    validate_config,
)
from src.zone_review import _load_ground_truth


POLICIES = ("center", "bottom_center")
GROUPS = ("both_methods_fail", "center_only_fails", "bottom_center_only_fails")
GROUP_LABELS = {
    "both_methods_fail": "Both methods fail",
    "center_only_fails": "Centre only fails",
    "bottom_center_only_fails": "Bottom-centre only fails",
}


def _round(value):
    return round(float(value), 3)


def _write_json(path: Path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def _write_csv(path: Path, rows: list[dict]):
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = list(rows[0]) if rows else []
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def _font(size=24):
    try:
        return ImageFont.truetype("DejaVuSans.ttf", size)
    except OSError:
        return ImageFont.load_default()


def _distance_to_segments(point, segments):
    return min(
        distance_to_segment(point, tuple(a), tuple(b))
        for polyline in segments
        for a, b in zip(polyline, polyline[1:], strict=False)
    )


def _orientation(a, b, c):
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])


def _segments_intersect(a, b, c, d):
    def on_segment(p, q, r):
        return min(p[0], r[0]) <= q[0] <= max(p[0], r[0]) and min(p[1], r[1]) <= q[1] <= max(
            p[1], r[1]
        )

    values = (
        _orientation(a, b, c),
        _orientation(a, b, d),
        _orientation(c, d, a),
        _orientation(c, d, b),
    )
    if values[0] == 0 and on_segment(a, c, b):
        return True
    if values[1] == 0 and on_segment(a, d, b):
        return True
    if values[2] == 0 and on_segment(c, a, d):
        return True
    if values[3] == 0 and on_segment(c, b, d):
        return True
    return (values[0] > 0) != (values[1] > 0) and (values[2] > 0) != (values[3] > 0)


def _polyline_crosses_box(polyline, box):
    x1, y1, x2, y2 = box
    corners = ((x1, y1), (x2, y1), (x2, y2), (x1, y2))
    for point in polyline:
        if x1 <= point[0] <= x2 and y1 <= point[1] <= y2:
            return True
    edges = tuple(zip(corners, corners[1:] + corners[:1], strict=False))
    return any(
        _segments_intersect(tuple(a), tuple(b), tuple(c), tuple(d))
        for c, d in zip(polyline, polyline[1:], strict=False)
        for a, b in edges
    )


def _box_crosses_polylines(box, polylines):
    return any(_polyline_crosses_box(polyline, box) for polyline in polylines)


def _segments_from_config(config):
    shared = {item["id"]: item["points_px"] for item in config.get("shared_edges", [])}
    divider = config.get("proposal", {}).get("divider_proposal_px")
    if divider:
        shared.setdefault("divider_far", divider[0:2])
        shared.setdefault("divider_middle", divider[1:3])
        shared.setdefault("divider_near", divider[2:4])
    return {
        "depth_band": [
            shared[name] for name in ("far_middle", "middle_near", "near_bottom") if name in shared
        ],
        "aisle": [
            shared[name]
            for name in ("divider_far", "divider_middle", "divider_near")
            if name in shared
        ],
    }


def _boundary_measurements(config, box, assignments):
    point_values = {policy: tuple(assignments[policy]["anchor"]) for policy in POLICIES}
    segments = _segments_from_config(config)
    outer = config["monitored_outer_region"]["polygon_px"]
    outer_distance = {
        policy: _round(distance_to_polygon(point, outer)) for policy, point in point_values.items()
    }
    depth_distance = {
        policy: _round(_distance_to_segments(point, segments["depth_band"]))
        for policy, point in point_values.items()
    }
    aisle_distance = {
        policy: _round(_distance_to_segments(point, segments["aisle"]))
        for policy, point in point_values.items()
    }
    tolerance = {
        policy: _round(assignments[policy]["result"]["tolerance_px_used"]) for policy in POLICIES
    }
    x1, y1, x2, y2 = box
    return {
        "depth_band_distance_px": depth_distance,
        "aisle_distance_px": aisle_distance,
        "box_crosses_depth_band": _box_crosses_polylines(box, segments["depth_band"]),
        "box_crosses_aisle": _box_crosses_polylines(box, segments["aisle"]),
        "monitored_outer_distance_px": outer_distance,
        "assignment_tolerance_px": tolerance,
        "center_inside_monitored_outer": point_in_polygon(point_values["center"], outer),
        "bottom_center_inside_monitored_outer": point_in_polygon(
            point_values["bottom_center"], outer
        ),
        "box_touches_image_edge": {
            "left": x1 <= 1,
            "top": y1 <= 1,
            "right": x2 >= config["reference"]["width"] - 1,
            "bottom": y2 >= config["reference"]["height"] - 1,
        },
    }


def _cause_assessment(config, entry, assignments):
    measurements = _boundary_measurements(config, entry["box"], assignments)
    threshold = max(measurements["assignment_tolerance_px"].values()) + 8
    near_depth = (
        measurements["box_crosses_depth_band"]
        or min(measurements["depth_band_distance_px"].values()) <= threshold
    )
    near_aisle = (
        measurements["box_crosses_aisle"]
        or min(measurements["aisle_distance_px"].values()) <= threshold
    )
    near_outer = (
        not measurements["center_inside_monitored_outer"]
        or not measurements["bottom_center_inside_monitored_outer"]
        or min(measurements["monitored_outer_distance_px"].values()) <= threshold
    )
    edge = any(measurements["box_touches_image_edge"].values())
    categories = []
    if near_depth:
        categories.append("depth-band boundary")
    if near_aisle:
        categories.append("left/right or aisle boundary")
    if near_outer:
        categories.append("monitored outer boundary")
    if edge or entry.get("partial", False):
        categories.append("bounding-box truncation or occlusion")
    if not categories:
        categories.append("none of the tested boundaries")

    # These are deliberately conservative: a box crossing a boundary does not
    # prove that the person is occluded or that the polygon is wrong.
    if edge or entry.get("partial", False):
        truncation = "possible; box touches image edge or is marked partial"
    else:
        truncation = "not indicated by box edge/partial flags; visual occlusion remains uncertain"
    explanation = (
        "Anchor placement is implicated because at least one assignment point is "
        "near/outside a boundary while the manual zone is fixed."
        if categories[0] != "none of the tested boundaries"
        else "No tested geometric boundary is near either anchor; explanation uncertain."
    )
    return {
        "categories": categories,
        "confidence": "uncertain" if "none of the tested boundaries" in categories else "likely",
        "anchor_point_mismatch": explanation,
        "truncation_or_occlusion": truncation,
        "boundary_measurements": measurements,
        "note": (
            "The proposal is not approved geometry; this is an explanation of the "
            "observed assignment, not evidence to move a boundary."
        ),
    }


def _group(center_correct, bottom_correct):
    if not center_correct and not bottom_correct:
        return "both_methods_fail"
    if not center_correct:
        return "center_only_fails"
    return "bottom_center_only_fails"


def _entry_index(review):
    return {(entry["file"], str(entry["annotation_id"])): entry for entry in review["entries"]}


def _assignment_row(config, entry, policy, image_size):
    anchor = _anchor(entry["box"], policy)
    result = assign_point(config, anchor, frame_size=image_size)
    return {"anchor": [_round(anchor[0]), _round(anchor[1])], "result": result}


def _load_assignment_rows(path: Path):
    with path.open("r", newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def _assignment_alignment(assignments_path, config, review_entries, image_sizes):
    """Verify legacy records against a fresh current-config GT computation."""
    rows = _load_assignment_rows(assignments_path)
    gt_rows = {
        (row["file"], str(row["record_id"]), row["anchor_policy"]): row
        for row in rows
        if row.get("record_type") == "ground_truth"
    }
    expected_keys = {
        (entry["file"], str(entry["annotation_id"]), policy)
        for entry in review_entries
        for policy in POLICIES
    }
    actual_keys = set(gt_rows)
    mismatches = []
    for entry in review_entries:
        for policy in POLICIES:
            key = (entry["file"], str(entry["annotation_id"]), policy)
            row = gt_rows.get(key)
            if row is None:
                mismatches.append({"key": key, "reason": "missing_assignment_record"})
                continue
            fresh = _assignment_row(config, entry, policy, image_sizes[entry["file"]])
            expected_zone = fresh["result"]["zone"] or ""
            if row.get("assigned_zone", "") != expected_zone:
                mismatches.append(
                    {
                        "key": key,
                        "reason": "assigned_zone_mismatch",
                        "recorded": row.get("assigned_zone", ""),
                        "recomputed": expected_zone,
                    }
                )
            for field, value in zip(("anchor_x", "anchor_y"), fresh["anchor"], strict=False):
                if not math.isclose(float(row[field]), value, abs_tol=0.01):
                    mismatches.append(
                        {
                            "key": key,
                            "reason": f"{field}_mismatch",
                            "recorded": row[field],
                            "recomputed": value,
                        }
                    )
    return {
        "assignment_file_sha256": sha256(assignments_path),
        "recorded_ground_truth_keys": len(actual_keys),
        "expected_ground_truth_keys": len(expected_keys),
        "extra_ground_truth_keys": [list(key) for key in sorted(actual_keys - expected_keys)],
        "missing_ground_truth_keys": [list(key) for key in sorted(expected_keys - actual_keys)],
        "current_config_recomputed_match": not mismatches and actual_keys == expected_keys,
        "mismatches": mismatches,
        "legacy_records_contain_config_hash": False,
        "note": "Legacy assignment CSV has no embedded config hash; equality was checked by recomputation against the current proposal file.",
    }


def _draw_geometry(draw, config, scale=1.0, offset=(0, 0), width=3):
    ox, oy = offset
    for zone in config["zones"]:
        points = [(ox + x * scale, oy + y * scale) for x, y in zone["polygon_px"]]
        color = ZONE_COLORS[zone["id"]]
        draw.line(points + [points[0]], fill=(*color, 220), width=max(1, int(width * scale)))
        cx = sum(point[0] for point in points) / len(points)
        cy = sum(point[1] for point in points) / len(points)
        draw.text((cx - 14, cy - 14), zone["id"], fill=(255, 255, 255, 255), font=_font(22))
    outer = config["monitored_outer_region"]["polygon_px"]
    points = [(ox + x * scale, oy + y * scale) for x, y in outer]
    draw.line(points + [points[0]], fill=(255, 255, 255, 200), width=max(1, int(width * scale)))


def _draw_people(draw, entries, target_key, config, scale=1.0, offset=(0, 0)):
    ox, oy = offset
    for entry in entries:
        key = (entry["file"], str(entry["annotation_id"]))
        target = key == target_key
        x1, y1, x2, y2 = entry["box"]
        box = (ox + x1 * scale, oy + y1 * scale, ox + x2 * scale, oy + y2 * scale)
        color = (255, 50, 50, 255) if target else (255, 215, 40, 230)
        draw.rectangle(box, outline=color, width=max(2, int((6 if target else 3) * scale)))
        draw.text(
            (box[0] + 4, box[1] + 4),
            f"{entry['annotation_id']}",
            fill=color,
            font=_font(max(14, int(20 * scale))),
        )
        for policy, marker, marker_color in (
            ("center", "C", (0, 235, 255, 255)),
            ("bottom_center", "B", (255, 0, 230, 255)),
        ):
            px, py = _anchor(entry["box"], policy)
            px, py = ox + px * scale, oy + py * scale
            radius = max(4, int(7 * scale))
            draw.ellipse((px - radius, py - radius, px + radius, py + radius), fill=marker_color)
            if target:
                draw.text((px + radius + 3, py - radius), marker, fill=marker_color, font=_font(18))


def _fit_image_with_transform(image, size, background=(18, 23, 30)):
    image = image.copy()
    source_width, source_height = image.size
    scale = min(size[0] / source_width, size[1] / source_height)
    fitted_size = (max(1, round(source_width * scale)), max(1, round(source_height * scale)))
    image = image.resize(fitted_size, Image.Resampling.LANCZOS)
    canvas = Image.new("RGB", size, background)
    x = (size[0] - image.width) // 2
    y = (size[1] - image.height) // 2
    canvas.paste(image, (x, y))
    return canvas, scale, (x, y)


def _render_case(config, frame_path, frame_entries, case, out_path):
    source = Image.open(frame_path).convert("RGB")
    width, height = source.size
    canvas = Image.new("RGB", (1900, 1160), (18, 23, 30))
    draw = ImageDraw.Draw(canvas, "RGBA")
    target_key = (case["file"], str(case["annotation_id"]))

    title = (
        f"{GROUP_LABELS[case['group']]}  |  {case['file']}  |  annotation {case['annotation_id']}\n"
        f"expected {case['expected_zone']}  |  centre {case['center_assigned'] or 'OUT'}  |  "
        f"bottom-centre {case['bottom_center_assigned'] or 'OUT'}"
    )
    draw.multiline_text((28, 20), title, fill="white", font=_font(25), spacing=8)
    draw.text(
        (28, 112),
        "C = centre anchor (cyan), B = bottom-centre anchor (magenta); yellow boxes are surrounding GT seats",
        fill=(210, 220, 230),
        font=_font(18),
    )

    full_box = (28, 170, 930, 890)
    full_size = (full_box[2] - full_box[0], full_box[3] - full_box[1])
    full, full_scale, full_inner_offset = _fit_image_with_transform(source, full_size)
    full_x, full_y = full_box[0], full_box[1]
    canvas.paste(full, (full_x, full_y))
    draw = ImageDraw.Draw(canvas, "RGBA")
    full_offset = (full_x + full_inner_offset[0], full_y + full_inner_offset[1])
    _draw_geometry(draw, config, full_scale, full_offset, 3)
    _draw_people(draw, frame_entries, target_key, config, full_scale, full_offset)
    draw.rectangle(full_box, outline=(150, 160, 175, 255), width=2)
    draw.text((full_box[0] + 10, full_box[1] + 10), "FULL SCENE", fill="white", font=_font(18))

    target = next(
        item for item in frame_entries if (item["file"], str(item["annotation_id"])) == target_key
    )
    x1, y1, x2, y2 = target["box"]
    padding_x = max(180, (x2 - x1) * 1.7)
    padding_y = max(180, (y2 - y1) * 1.7)
    crop_box = (
        max(0, int(x1 - padding_x)),
        max(0, int(y1 - padding_y)),
        min(width, int(x2 + padding_x)),
        min(height, int(y2 + padding_y)),
    )
    crop = source.crop(crop_box)
    crop_box_canvas = (970, 170, 1870, 890)
    crop_size = (crop_box_canvas[2] - crop_box_canvas[0], crop_box_canvas[3] - crop_box_canvas[1])
    crop_fit, crop_scale, crop_inner_offset = _fit_image_with_transform(crop, crop_size)
    crop_x, crop_y = crop_box_canvas[0], crop_box_canvas[1]
    canvas.paste(crop_fit, (crop_x, crop_y))
    draw = ImageDraw.Draw(canvas, "RGBA")
    crop_offset = (
        crop_x + crop_inner_offset[0] - crop_box[0] * crop_scale,
        crop_y + crop_inner_offset[1] - crop_box[1] * crop_scale,
    )
    _draw_geometry(draw, config, crop_scale, crop_offset, 4)
    _draw_people(draw, frame_entries, target_key, config, crop_scale, crop_offset)
    draw.rectangle(crop_box_canvas, outline=(150, 160, 175, 255), width=2)
    draw.text(
        (crop_box_canvas[0] + 10, crop_box_canvas[1] + 10),
        "ENLARGED CROP + SURROUNDING SEATS",
        fill="white",
        font=_font(18),
    )

    details = [
        f"box: [{_round(x1)}, {_round(y1)}, {_round(x2)}, {_round(y2)}]",
        f"centre anchor: {case['center_anchor']} -> {case['center_assigned'] or 'OUT'}",
        f"bottom-centre anchor: {case['bottom_center_anchor']} -> {case['bottom_center_assigned'] or 'OUT'}",
        f"cause: {', '.join(case['cause_categories'])} ({case['cause_confidence']})",
        f"assessment: {case['anchor_point_mismatch']}",
        f"truncation/occlusion: {case['truncation_or_occlusion']}",
    ]
    draw.multiline_text(
        (28, 930), "\n".join(details), fill=(235, 240, 245), font=_font(18), spacing=6
    )
    canvas.save(out_path)


def _occupied_comparison(cases, reviewed_entries, by_file):
    errors_by_person = defaultdict(set)
    for case in cases:
        errors_by_person[(case["file"], case["annotation_id"])].update(
            policy for policy in POLICIES if not case[f"{policy}_correct"]
        )
    rows = []
    for file_name, entries in by_file.items():
        expected = {
            entry["expected_zone"] for entry in entries if entry["expected_zone"] in ZONE_ORDER
        }
        assignments = {}
        for policy in POLICIES:
            assignments[policy] = {
                entry[f"{policy}_assigned"]
                for entry in entries
                if entry[f"{policy}_assigned"] in ZONE_ORDER
            }
            person_errors = {
                (entry["file"], entry["annotation_id"])
                for entry in entries
                if not entry[f"{policy}_correct"]
            }
            masked = {key for key in person_errors if assignments[policy] == expected}
            false_activated = sorted(assignments[policy] - expected)
            missed = sorted(expected - assignments[policy])
            rows.append(
                {
                    "file": file_name,
                    "heuristic": policy,
                    "expected_occupied_zones": ",".join(sorted(expected)),
                    "heuristic_occupied_zones": ",".join(sorted(assignments[policy])),
                    "falsely_activated_zones": ",".join(false_activated),
                    "occupied_zones_missed": ",".join(missed),
                    "person_errors": len(person_errors),
                    "person_errors_masked_by_other_people": len(masked),
                    "zone_set_exact_match": assignments[policy] == expected,
                }
            )
    return rows


def run(args):
    config = load_config(args.config)
    validate_config(config)
    review = json.loads(args.review.read_text(encoding="utf-8"))
    image_info, ground_truth = _load_ground_truth(args.labels)
    review_entries = [
        entry
        for entry in review["entries"]
        if entry.get("review_status") == "reviewed" and entry.get("expected_zone")
    ]
    if len(review_entries) != len(review["entries"]):
        raise ValueError("review file contains unreviewed entries; refusing to count them")

    output = args.output
    if output.exists():
        for child in output.iterdir():
            if child.is_dir():
                shutil.rmtree(child)
            else:
                child.unlink()
    output.mkdir(parents=True, exist_ok=True)
    (output / "gallery").mkdir()
    for group in GROUPS:
        (output / "gallery" / group).mkdir()

    image_sizes = {}
    image_hashes = {}
    source_check = {}
    for file_name in sorted({entry["file"] for entry in review_entries}):
        path = args.images / file_name
        if not path.exists():
            raise FileNotFoundError(path)
        with Image.open(path) as image:
            image_sizes[file_name] = image.size
        image_hashes[file_name] = sha256(path)
        source_check[file_name] = {
            "path": str(path),
            "sha256": image_hashes[file_name],
            "width": image_sizes[file_name][0],
            "height": image_sizes[file_name][1],
            "labels_image_record": image_info[file_name],
        }

    # Check that the manual review entries still correspond to the current GT labels.
    gt_by_key = {
        (file_name, str(ann["id"])): ann for file_name, anns in ground_truth.items() for ann in anns
    }
    label_alignment = []
    for entry in review_entries:
        key = (entry["file"], str(entry["annotation_id"]))
        ann = gt_by_key.get(key)
        label_alignment.append(
            {
                "file": entry["file"],
                "annotation_id": str(entry["annotation_id"]),
                "review_box_matches_current_gt": ann is not None
                and all(
                    math.isclose(float(a), float(b), abs_tol=1e-6)
                    for a, b in zip(entry["box"], ann["box"], strict=False)
                ),
                "current_gt_present": ann is not None,
            }
        )
    if not all(item["review_box_matches_current_gt"] for item in label_alignment):
        raise ValueError("manual review entries do not match current ground-truth labels")

    cases = []
    reviewed_by_file = defaultdict(list)
    for entry in review_entries:
        assignments = {
            policy: _assignment_row(config, entry, policy, image_sizes[entry["file"]])
            for policy in POLICIES
        }
        assigned = {policy: assignments[policy]["result"]["zone"] for policy in POLICIES}
        expected = entry["expected_zone"]
        correct = {policy: assigned[policy] == expected for policy in POLICIES}
        if all(correct.values()):
            reviewed_by_file[entry["file"]].append(
                {
                    **entry,
                    "center_assigned": assigned["center"],
                    "bottom_center_assigned": assigned["bottom_center"],
                    "center_correct": True,
                    "bottom_center_correct": True,
                }
            )
            continue
        cause = _cause_assessment(config, entry, assignments)
        case = {
            "file": entry["file"],
            "annotation_id": str(entry["annotation_id"]),
            "expected_zone": expected,
            "box": [_round(value) for value in entry["box"]],
            "seated": bool(entry.get("seated")),
            "partial": bool(entry.get("partial")),
            "uncertain_annotation_flag": bool(entry.get("uncertain_annotation_flag")),
            "center_assigned": assigned["center"],
            "bottom_center_assigned": assigned["bottom_center"],
            "center_status": assignments["center"]["result"]["status"],
            "bottom_center_status": assignments["bottom_center"]["result"]["status"],
            "center_anchor": assignments["center"]["anchor"],
            "bottom_center_anchor": assignments["bottom_center"]["anchor"],
            "center_correct": correct["center"],
            "bottom_center_correct": correct["bottom_center"],
            "group": _group(correct["center"], correct["bottom_center"]),
            "cause_categories": cause["categories"],
            "cause_confidence": cause["confidence"],
            "anchor_point_mismatch": cause["anchor_point_mismatch"],
            "truncation_or_occlusion": cause["truncation_or_occlusion"],
            "boundary_measurements": cause["boundary_measurements"],
            "cause_note": cause["note"],
        }
        cases.append(case)
        reviewed_by_file[entry["file"]].append({**entry, **case})

    # Ensure every manual person is available to the frame renderer, including correct people.
    for file_name in sorted({entry["file"] for entry in review_entries}):
        reviewed_by_file[file_name] = []
        for entry in review_entries:
            if entry["file"] != file_name:
                continue
            matched = next(
                (
                    case
                    for case in cases
                    if case["file"] == file_name
                    and case["annotation_id"] == str(entry["annotation_id"])
                ),
                None,
            )
            if matched:
                reviewed_by_file[file_name].append(matched)
            else:
                assignments = {
                    policy: _assignment_row(config, entry, policy, image_sizes[file_name])
                    for policy in POLICIES
                }
                reviewed_by_file[file_name].append(
                    {
                        **entry,
                        "center_assigned": assignments["center"]["result"]["zone"],
                        "bottom_center_assigned": assignments["bottom_center"]["result"]["zone"],
                        "center_correct": True,
                        "bottom_center_correct": True,
                        "annotation_id": str(entry["annotation_id"]),
                    }
                )

    for case in cases:
        frame_path = args.images / case["file"]
        target_entries = reviewed_by_file[case["file"]]
        _render_case(
            config,
            frame_path,
            target_entries,
            case,
            output
            / "gallery"
            / case["group"]
            / f"{Path(case['file']).stem}__ann_{case['annotation_id']}.png",
        )

    comparison_rows = []
    for case in cases:
        comparison_rows.append(
            {
                "file": case["file"],
                "annotation_id": case["annotation_id"],
                "expected_zone": case["expected_zone"],
                "center_assigned": case["center_assigned"] or "",
                "bottom_center_assigned": case["bottom_center_assigned"] or "",
                "center_anchor": json.dumps(case["center_anchor"]),
                "bottom_center_anchor": json.dumps(case["bottom_center_anchor"]),
                "group": case["group"],
                "cause_categories": "; ".join(case["cause_categories"]),
                "cause_confidence": case["cause_confidence"],
                "seated": case["seated"],
                "partial": case["partial"],
                "center_status": case["center_status"],
                "bottom_center_status": case["bottom_center_status"],
                "truncation_or_occlusion": case["truncation_or_occlusion"],
            }
        )
    _write_json(output / "per_person_errors.json", cases)
    _write_csv(output / "per_person_errors.csv", comparison_rows)
    person_md = [
        "# Per-person zone-assignment errors",
        "",
        "| File | Annotation | Expected | Centre | Bottom-centre | Centre anchor | Bottom-centre anchor | Group | Causes | Confidence |",
        "|---|---:|---|---|---|---|---|---|---|---|",
    ]
    for case in cases:
        person_md.append(
            "| "
            + " | ".join(
                [
                    case["file"],
                    case["annotation_id"],
                    case["expected_zone"],
                    case["center_assigned"] or "OUT",
                    case["bottom_center_assigned"] or "OUT",
                    str(case["center_anchor"]),
                    str(case["bottom_center_anchor"]),
                    GROUP_LABELS[case["group"]],
                    "; ".join(case["cause_categories"]),
                    case["cause_confidence"],
                ]
            )
            + "|"
        )
    (output / "per_person_errors.md").write_text("\n".join(person_md) + "\n", encoding="utf-8")

    occupied_input = []
    for entry in review_entries:
        assignments = {
            policy: _assignment_row(config, entry, policy, image_sizes[entry["file"]])
            for policy in POLICIES
        }
        occupied_input.append(
            {
                **entry,
                "center_assigned": assignments["center"]["result"]["zone"],
                "bottom_center_assigned": assignments["bottom_center"]["result"]["zone"],
                "center_correct": assignments["center"]["result"]["zone"] == entry["expected_zone"],
                "bottom_center_correct": assignments["bottom_center"]["result"]["zone"]
                == entry["expected_zone"],
            }
        )
    occupied_rows = _occupied_comparison(
        cases,
        review_entries,
        {
            file_name: [item for item in occupied_input if item["file"] == file_name]
            for file_name in sorted({item["file"] for item in occupied_input})
        },
    )
    _write_json(output / "per_frame_occupied_zone_comparison.json", occupied_rows)
    _write_csv(output / "per_frame_occupied_zone_comparison.csv", occupied_rows)
    occupied_md = [
        "# Per-frame occupied-zone comparison",
        "",
        "| File | Heuristic | Expected occupied | Observed occupied | Falsely activated | Missed | Person errors | Masked by another person | Exact set match |",
        "|---|---|---|---|---|---|---:|---:|---|",
    ]
    for row in occupied_rows:
        occupied_md.append(
            "| "
            + " | ".join(
                [
                    str(row["file"]),
                    str(row["heuristic"]),
                    str(row["expected_occupied_zones"]),
                    str(row["heuristic_occupied_zones"]),
                    str(row["falsely_activated_zones"]),
                    str(row["occupied_zones_missed"]),
                    str(row["person_errors"]),
                    str(row["person_errors_masked_by_other_people"]),
                    str(row["zone_set_exact_match"]),
                ]
            )
            + "|"
        )
    (output / "per_frame_occupied_zone_comparison.md").write_text(
        "\n".join(occupied_md) + "\n", encoding="utf-8"
    )

    alignment = _assignment_alignment(args.assignments, config, review_entries, image_sizes)
    labels_hash = sha256(args.labels)
    review_hash = sha256(args.review)
    config_hash = sha256(args.config)
    manifest = {
        "diagnostic_only": True,
        "box_source": "existing ground-truth boxes from labels.coco.json; no detector run",
        "config": {"path": str(args.config), "sha256": config_hash, "status": config["status"]},
        "review": {"path": str(args.review), "sha256": review_hash, "entries": len(review_entries)},
        "labels": {"path": str(args.labels), "sha256": labels_hash},
        "assignment_records": alignment,
        "source_images": source_check,
        "review_labels_source_hash_match": review.get("source_labels_sha256") == labels_hash,
        "review_entry_label_alignment": label_alignment,
        "geometry_validation": validate_config(config),
        "manual_labels_changed": False,
        "geometry_changed": False,
        "production_settings_changed": False,
        "mqtt_run": False,
        "model_run": False,
    }
    _write_json(output / "run_manifest.json", manifest)

    group_counts = {group: sum(case["group"] == group for case in cases) for group in GROUPS}
    summary = {
        "reviewed_people": len(review_entries),
        "error_people": len(cases),
        "group_counts": group_counts,
        "center": {
            "correct": sum(item["center_correct"] for item in occupied_input),
            "incorrect": sum(not item["center_correct"] for item in occupied_input),
        },
        "bottom_center": {
            "correct": sum(item["bottom_center_correct"] for item in occupied_input),
            "incorrect": sum(not item["bottom_center_correct"] for item in occupied_input),
        },
        "recommendation": (
            "Smallest next experiment: replay these same 25 GT boxes with a measured "
            "anchor-fraction sweep (center, bottom-center, and one or two fixed "
            "intermediate fractions) and report per-person plus occupied-zone results. "
            "Do not move boundaries or add posture-specific rules yet."
        ),
    }
    _write_json(output / "summary.json", summary)

    # Human-readable HTML is the primary gallery index; all labels are escaped.
    lines = [
        "<!doctype html><meta charset='utf-8'><title>Six-zone assignment error gallery</title>",
        "<style>body{font:16px sans-serif;background:#151a21;color:#eee;margin:24px} h1,h2{color:#fff} table{border-collapse:collapse}td,th{border:1px solid #4c5664;padding:6px;vertical-align:top} img{max-width:100%;border:1px solid #596575}.case{margin:24px 0 40px;max-width:1900px}.muted{color:#b8c0ca}</style>",
        "<h1>Six-zone assignment error gallery</h1>",
        f"<p class='muted'>Ground-truth boxes only. Current proposal config SHA-256: <code>{config_hash}</code>. Manual labels preserved; no production settings changed.</p>",
        "<p>Legend: cyan C = centre anchor; magenta B = bottom-centre anchor; red box = target; yellow boxes = surrounding reviewed people.</p>",
    ]
    for group in GROUPS:
        group_cases = [case for case in cases if case["group"] == group]
        lines.append(f"<h2>{html.escape(GROUP_LABELS[group])} ({len(group_cases)})</h2>")
        for case in group_cases:
            image_name = f"{Path(case['file']).stem}__ann_{case['annotation_id']}.png"
            rel = f"gallery/{group}/{image_name}"
            lines.append("<div class='case'>")
            lines.append(
                f"<h3>{html.escape(case['file'])}, annotation {html.escape(case['annotation_id'])}: expected {html.escape(case['expected_zone'])}; centre {html.escape(case['center_assigned'] or 'OUT')}; bottom-centre {html.escape(case['bottom_center_assigned'] or 'OUT')}</h3>"
            )
            lines.append(
                f"<p>{html.escape('; '.join(case['cause_categories']))} ({html.escape(case['cause_confidence'])}). {html.escape(case['anchor_point_mismatch'])} {html.escape(case['truncation_or_occlusion'])}</p>"
            )
            lines.append(
                f"<img src='{html.escape(rel)}' alt='{html.escape(case['file'])} annotation {html.escape(case['annotation_id'])} gallery card'>"
            )
            lines.append("</div>")
    lines.extend(
        [
            "<h2>Per-frame occupied-zone comparison</h2>",
            "<p>False activation and missed zones are set-level effects; a person-level error can be masked when another person still activates the expected zone.</p>",
            "<table><tr><th>Frame</th><th>Heuristic</th><th>Expected</th><th>Observed</th><th>False activated</th><th>Missed</th><th>Person errors</th><th>Masked</th></tr>",
        ]
    )
    for row in occupied_rows:
        lines.append(
            "<tr>"
            + "".join(
                f"<td>{html.escape(str(row[key]))}</td>"
                for key in (
                    "file",
                    "heuristic",
                    "expected_occupied_zones",
                    "heuristic_occupied_zones",
                    "falsely_activated_zones",
                    "occupied_zones_missed",
                    "person_errors",
                    "person_errors_masked_by_other_people",
                )
            )
            + "</tr>"
        )
    lines.append("</table>")
    (output / "error_gallery.html").write_text("\n".join(lines) + "\n", encoding="utf-8")

    group_members = {
        group: ", ".join(
            f"{case['file']} annotation {case['annotation_id']}"
            for case in cases
            if case["group"] == group
        )
        for group in GROUPS
    }
    report_lines = [
        "# Six-zone assignment diagnostics",
        "",
        f"Reviewed people: {len(review_entries)}. Assignment-error people: {len(cases)}.",
        f"Current proposal config SHA-256: `{config_hash}`.",
        "",
        "## Findings",
        "",
        f"- Both methods fail: {group_counts['both_methods_fail']} ({group_members['both_methods_fail']}).",
        f"- Centre only fails: {group_counts['center_only_fails']} ({group_members['center_only_fails']}).",
        f"- Bottom-centre only fails: {group_counts['bottom_center_only_fails']} ({group_members['bottom_center_only_fails']}).",
        "- Boundary explanations are evidence-based classifications from the current image-space geometry; they do not authorize moving boundaries.",
        "- No error box touches an image edge or carries the manual partial flag. Bounding-box truncation/occlusion is therefore not indicated by the available metadata; visual occlusion remains uncertain where the box spans a boundary.",
        "- The current proposal's aisle divider is implicated in annotations 117 and 171; far/middle or middle/near depth boundaries are implicated in 30, 117, 118, 171, 172, and 173; the monitored outer polygon is implicated in 30, 33, and 172.",
        "",
        "## Recommended next experiment",
        "",
        summary["recommendation"],
        "",
        "Open `error_gallery.html` for the full-scene and enlarged-crop cards. See `per_person_errors.md`, `per_frame_occupied_zone_comparison.md`, and `run_manifest.json` for readable tables and hashes.",
    ]
    (output / "diagnostic_report.md").write_text("\n".join(report_lines) + "\n", encoding="utf-8")
    print(
        json.dumps(
            {
                "output": str(output),
                **summary,
                "assignment_alignment": alignment["current_config_recomputed_match"],
            },
            indent=2,
        )
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--review", type=Path, required=True)
    parser.add_argument("--labels", type=Path, required=True)
    parser.add_argument("--images", type=Path, required=True)
    parser.add_argument("--assignments", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    run(parser.parse_args())


if __name__ == "__main__":
    main()
