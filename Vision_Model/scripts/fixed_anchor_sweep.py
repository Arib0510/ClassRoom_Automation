"""Run a fixed-fraction anchor sweep on the completed manual zone review.

Diagnostic only: reads existing proposals, reviewed boxes and source images;
does not alter labels/configuration or access inference, MQTT, or hardware.
Run from Vision_Model with ``python scripts/fixed_anchor_sweep.py``.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import sys
from collections import defaultdict
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from src.zone_definition import ZONE_COLORS, ZONE_ORDER, assign_point, load_config, sha256, validate_config
from src.zone_review import _load_ground_truth

FRACTIONS = (0.50, 0.625, 0.75, 0.875, 1.00)
MARKER_COLORS = ((60, 240, 255), (90, 255, 120), (255, 220, 50), (255, 145, 50), (255, 65, 190))


def _write_json(path: Path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def _load_csv(path: Path):
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def _font(size=20):
    try:
        return ImageFont.truetype("DejaVuSans.ttf", size)
    except OSError:
        return ImageFont.load_default()


def _assign(config, box, fraction, size):
    x1, y1, x2, y2 = map(float, box)
    point = ((x1 + x2) / 2, y1 + fraction * (y2 - y1))
    result = assign_point(config, point, frame_size=size)
    return {"point": [round(point[0], 3), round(point[1], 3)], "zone": result["zone"], "status": result["status"]}


def _appliance_sets(config, occupied):
    mapping = {zone["id"]: zone["appliance"] for zone in config["zones"]}
    fans = {mapping[z]["fan"] for z in occupied}
    lights = {mapping[z]["light"] for z in occupied}
    shared = {mapping[z]["shared"] for z in occupied}
    return {"fan": fans, "zone_light": lights, "shared_light": shared}


def _set_delta(expected, actual):
    return {"missing": sorted(expected - actual), "false": sorted(actual - expected)}


def _draw_case(config, image_path, entries, target, evaluated, output):
    image = Image.open(image_path).convert("RGB")
    draw = ImageDraw.Draw(image, "RGBA")
    for zone in config["zones"]:
        pts = [tuple(map(int, p)) for p in zone["polygon_px"]]
        draw.line(pts + [pts[0]], fill=(*ZONE_COLORS[zone["id"]], 230), width=4)
        cx = sum(p[0] for p in pts) // len(pts); cy = sum(p[1] for p in pts) // len(pts)
        draw.text((cx, cy), zone["id"], fill="white", font=_font(22), stroke_width=2, stroke_fill="black")
    x1, y1, x2, y2 = target["box"]
    cx = (x1 + x2) / 2
    draw.rectangle((x1, y1, x2, y2), outline=(255, 45, 45, 255), width=6)
    # On annotation 171 this displays the complete anchor path across the box.
    draw.line((cx, y1, cx, y2), fill=(255, 255, 255, 245), width=3)
    for fraction, color in zip(FRACTIONS, MARKER_COLORS, strict=True):
        y = y1 + fraction * (y2 - y1)
        draw.ellipse((cx - 9, y - 9, cx + 9, y + 9), fill=(*color, 255), outline=(0, 0, 0, 255), width=2)
        draw.text((cx + 12, y - 14), f"f={fraction:.3f} {evaluated[str(fraction)]['zone'] or 'OUT'}", fill=(*color, 255), font=_font(18), stroke_width=2, stroke_fill="black")
    title = f"{target['file']} | ann {target['annotation_id']} | expected {target['expected_zone']} | fixed-fraction diagnostics"
    draw.rectangle((0, 0, image.width, 42), fill=(0, 0, 0, 205))
    draw.text((12, 8), title, fill="white", font=_font(20))
    output.parent.mkdir(parents=True, exist_ok=True)
    image.save(output)


def run(args):
    config = load_config(args.config)
    validate_config(config)
    review = json.loads(args.review.read_text(encoding="utf-8"))
    image_info, ground_truth = _load_ground_truth(args.labels)
    entries = [e for e in review["entries"] if e.get("review_status") == "reviewed" and e.get("expected_zone") in ZONE_ORDER]
    if len(entries) != 25 or len(entries) != len(review["entries"]):
        raise ValueError(f"Expected exactly 25 completed zone labels; found {len(entries)} reviewed of {len(review['entries'])}")
    gt = {(name, str(row["id"])): row for name, rows in ground_truth.items() for row in rows}
    sizes, image_hashes = {}, {}
    for name in sorted({e["file"] for e in entries}):
        p = args.images / name
        with Image.open(p) as im:
            sizes[name] = im.size
        image_hashes[name] = sha256(p)
        info = image_info[name]
        if info.get("reviewed") is not True or not info.get("reviewed_by"):
            raise ValueError(f"Source labels are not fully reviewed for {name}")
    alignment = []
    for e in entries:
        ann = gt.get((e["file"], str(e["annotation_id"])))
        same = ann is not None and all(math.isclose(float(a), float(b), abs_tol=1e-6) for a, b in zip(e["box"], ann["box"], strict=True))
        alignment.append({"file": e["file"], "annotation_id": e["annotation_id"], "box_matches_current_gt": same})
    if not all(x["box_matches_current_gt"] for x in alignment):
        raise ValueError("Review entries differ from current ground-truth boxes")

    prior_rows = _load_csv(args.assignments)
    prior = {(r["file"], str(r["record_id"]), r["anchor_policy"]): r for r in prior_rows if r.get("record_type") == "ground_truth"}
    results = {f: [] for f in FRACTIONS}
    details = []
    by_frame = defaultdict(list)
    for e in entries:
        item = {**e, "fraction_results": {}}
        for f in FRACTIONS:
            assigned = _assign(config, e["box"], f, sizes[e["file"]])
            correct = assigned["zone"] == e["expected_zone"]
            assigned.update({"correct": correct, "category": "correct" if correct else ("outside" if assigned["zone"] is None else "wrong_zone")})
            item["fraction_results"][str(f)] = assigned
            results[f].append({**e, **assigned, "fraction": f})
        details.append(item)
        by_frame[e["file"]].append(item)

    # Verify exact baseline equivalence to existing records and policies.
    baseline = {}
    for f, policy in ((0.50, "center"), (1.00, "bottom_center")):
        mismatch = []
        for e in entries:
            row = prior.get((e["file"], str(e["annotation_id"]), policy))
            now = _assign(config, e["box"], f, sizes[e["file"]])
            if row is None or (row.get("assigned_zone") or None) != now["zone"]:
                mismatch.append({"file": e["file"], "annotation_id": e["annotation_id"], "prior": row.get("assigned_zone") if row else "MISSING", "sweep": now["zone"]})
        baseline[str(f)] = {"policy": policy, "exact_reproduction": not mismatch, "mismatches": mismatch}
    if not all(x["exact_reproduction"] for x in baseline.values()):
        raise ValueError(f"Anchor baselines failed exact reproduction check: {baseline}")

    summaries = []
    frame_results = {f: [] for f in FRACTIONS}
    for f in FRACTIONS:
        people = results[f]
        categories = CounterLike(r["category"] for r in people)
        breakdown = {}
        for flag in ("seated", "partial"):
            selected = [r for r in people if r.get(flag)]
            breakdown[flag] = {"n": len(selected), "correct": sum(r["correct"] for r in selected), "wrong_zone": sum(r["category"] == "wrong_zone" for r in selected), "outside": sum(r["category"] == "outside" for r in selected)}
        misses = false = exact = 0
        appliance_totals = {k: {"missing": 0, "false": 0} for k in ("fan", "zone_light", "shared_light")}
        for filename, frame in by_frame.items():
            expected = {e["expected_zone"] for e in frame}
            actual = {e["fraction_results"][str(f)]["zone"] for e in frame} - {None}
            missed, falsely = expected - actual, actual - expected
            misses += len(missed); false += len(falsely); exact += actual == expected
            exp_devices, act_devices = _appliance_sets(config, expected), _appliance_sets(config, actual)
            deltas = {kind: _set_delta(exp_devices[kind], act_devices[kind]) for kind in exp_devices}
            for kind, delta in deltas.items():
                appliance_totals[kind]["missing"] += len(delta["missing"])
                appliance_totals[kind]["false"] += len(delta["false"])
            frame_results[f].append({"file": filename, "expected_zones": sorted(expected), "assigned_zones": sorted(actual), "missed_zones": sorted(missed), "false_zones": sorted(falsely), "exact_match": actual == expected, "appliance_discrepancies": deltas})
        summaries.append({"fraction": f, **categories, "people": len(people), "missed_occupied_zones": misses, "falsely_occupied_zones": false, "frames_exact_zone_set": exact, "frames": len(by_frame), "breakdown": breakdown, "appliance_discrepancies": appliance_totals})

    output = args.output
    output.mkdir(parents=True, exist_ok=True)
    overlay_dir = output / "remaining_error_overlays"
    for e in details:
        failures = {f: e["fraction_results"][str(f)] for f in FRACTIONS if not e["fraction_results"][str(f)]["correct"]}
        if failures:
            _draw_case(config, args.images / e["file"], by_frame[e["file"]], e, e["fraction_results"], overlay_dir / f"{Path(e['file']).stem}__ann_{e['annotation_id']}.png")

    case171 = next(e for e in details if str(e["annotation_id"]) == "171")
    box171 = case171["box"]
    path171 = {"file": case171["file"], "annotation_id": 171, "expected_zone_preserved": case171["expected_zone"], "anchor_x": round((box171[0] + box171[2]) / 2, 3), "path_y_px": [round(box171[1], 3), round(box171[3], 3)], "tested_assignments": {str(f): case171["fraction_results"][str(f)]["zone"] for f in FRACTIONS}, "any_fraction_reaches_expected_zone": any(case171["fraction_results"][str(f)]["zone"] == case171["expected_zone"] for f in FRACTIONS), "resolution": "fixed-anchor sweep cannot resolve this mapping case; human review of the expected zone or image-space mapping is required; no automatic change made"}
    manifest = {"diagnostic_only": True, "experiment": "fixed_anchor_fraction_sweep", "fractions": list(FRACTIONS), "formula": "x=(x1+x2)/2; y=y1+f*(y2-y1)", "person_count": len(entries), "frame_count": len(by_frame), "baseline_reproduction": baseline, "annotation_171_inspection": path171, "hashes": {"config": {"path": str(args.config), "sha256": sha256(args.config)}, "review": {"path": str(args.review), "sha256": sha256(args.review)}, "labels": {"path": str(args.labels), "sha256": sha256(args.labels)}, "prior_error_manifest": {"path": str(args.error_manifest), "sha256": sha256(args.error_manifest)}, "prior_assignments": {"path": str(args.assignments), "sha256": sha256(args.assignments)}, "source_images": image_hashes}, "review_alignment": alignment, "geometry_changed": False, "manual_labels_changed": False, "appliance_mappings_changed": False, "live_mqtt": False, "appliances_operated": False, "model_run": False, "training_run": False, "production_settings_changed": False}
    _write_json(output / "run_manifest.json", manifest)
    _write_json(output / "comparison.json", {"diagnostic_only": True, "summary": summaries, "per_frame": {str(f): frame_results[f] for f in FRACTIONS}, "per_person": details})
    with (output / "comparison.csv").open("w", newline="", encoding="utf-8") as h:
        writer = csv.DictWriter(h, fieldnames=["fraction", "people", "correct", "wrong_zone", "outside", "missed_occupied_zones", "falsely_occupied_zones", "frames_exact_zone_set", "frames", "seated_n", "seated_correct", "seated_wrong_zone", "seated_outside", "partial_n", "partial_correct", "partial_wrong_zone", "partial_outside", "fan_missing", "fan_false", "zone_light_missing", "zone_light_false", "shared_light_missing", "shared_light_false"])
        writer.writeheader()
        for s in summaries:
            row = {k: s[k] for k in ("fraction", "people", "correct", "wrong_zone", "outside", "missed_occupied_zones", "falsely_occupied_zones", "frames_exact_zone_set", "frames")}
            for flag in ("seated", "partial"):
                row.update({f"{flag}_{key}": value for key, value in s["breakdown"][flag].items()})
            for kind, prefix in (("fan", "fan"), ("zone_light", "zone_light"), ("shared_light", "shared_light")):
                row[f"{prefix}_missing"] = s["appliance_discrepancies"][kind]["missing"]
                row[f"{prefix}_false"] = s["appliance_discrepancies"][kind]["false"]
            writer.writerow(row)
    _write_json(output / "summary.json", {"diagnostic_only": True, "baseline_reproduction": baseline, "results": summaries})
    lines = ["# Fixed-anchor fraction sweep (diagnostic only)", "", f"Reviewed people: {len(entries)}; frames: {len(by_frame)}. All five global fractions applied to every box.", "", "| f | Correct | Wrong zone | Outside | Missed zones | False zones | Exact frame sets | Seated correct/n | Partial correct/n | Fan miss/false | Zone-light miss/false | Shared-light miss/false |", "|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for s in summaries:
        app=s["appliance_discrepancies"]
        lines.append(f"| {s['fraction']:.3f} | {s['correct']} | {s['wrong_zone']} | {s['outside']} | {s['missed_occupied_zones']} | {s['falsely_occupied_zones']} | {s['frames_exact_zone_set']}/{s['frames']} | {s['breakdown']['seated']['correct']}/{s['breakdown']['seated']['n']} | {s['breakdown']['partial']['correct']}/{s['breakdown']['partial']['n']} | {app['fan']['missing']}/{app['fan']['false']} | {app['zone_light']['missing']}/{app['zone_light']['false']} | {app['shared_light']['missing']}/{app['shared_light']['false']} |")
    lines += ["", "Counts are diagnostic set differences accumulated across frames. Appliance activations use the existing per-zone mappings; shared lights use their mapped group and activate when either mapped zone is occupied.", "", f"Baseline reproduction: f=.50 centre={baseline['0.5']['exact_reproduction']}; f=1.00 bottom-centre={baseline['1.0']['exact_reproduction']}.", "", "## Annotation 171", "", "The reviewed expected label remains Z2. Its box centre x=844.346 px; the full anchor path runs from y=805.308 to 1133.231 px. Every tested fraction assigns Z1, so this fixed-anchor sweep cannot resolve the case. The overlay shows the complete path against the unchanged proposal divider. A human must resolve whether the reviewed mapping or the image-space divider represents the intended zone; neither was changed automatically.", "", "## Provisional offline-replay policy", "", "For further offline comparison only, use f=0.750 as the candidate replay anchor: it gives the highest person count (23/25) and lowest person wrong-zone count (2), while still missing one occupied zone, falsely occupying one zone, and producing one missing plus one false fan and zone-light activation across the five frames. It does not improve exact frame-set matches over f=0.500 or 0.625 (3/5), and it leaves one shared-light miss. Keep the current centre result as the baseline and retain f=0.750 as diagnostic output only; these five frames do not establish an operational policy.", "", f"Remaining-error overlays: `{overlay_dir}`.", ""]
    (output / "report.md").write_text("\n".join(lines), encoding="utf-8")
    print(json.dumps({"output": str(output), "summary": summaries, "baseline_reproduction": baseline}, indent=2))


def CounterLike(values):
    from collections import Counter
    counts = Counter(values)
    return {"correct": counts["correct"], "wrong_zone": counts["wrong_zone"], "outside": counts["outside"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=Path("config/zones/diagnostic_six_zone_aisle_proposal.json"))
    parser.add_argument("--review", type=Path, default=Path("outputs/zone_definition/manual_review/expected_zone_review.json"))
    parser.add_argument("--labels", type=Path, default=Path("outputs/dataset_diagnosis/review_set/ground_truth/labels.coco.json"))
    parser.add_argument("--images", type=Path, default=Path("outputs/dataset_diagnosis/review_set/images"))
    parser.add_argument("--assignments", type=Path, default=Path("outputs/zone_definition/person_zone_aisle_proposal/assignments.csv"))
    parser.add_argument("--error-manifest", type=Path, default=Path("outputs/zone_definition/manual_review/error_diagnostics_20261116/run_manifest.json"))
    parser.add_argument("--output", type=Path, default=Path("outputs/zone_definition/manual_review/fixed_anchor_sweep_20261117"))
    args = parser.parse_args()
    run(args)


if __name__ == "__main__":
    main()
