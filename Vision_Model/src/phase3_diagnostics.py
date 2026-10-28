"""Offline classroom preprocessing experiment; predictions never become human labels."""

from __future__ import annotations

import argparse
import csv
import json
import math
from dataclasses import asdict
from pathlib import Path

from PIL import Image, ImageDraw

from .config import REPO_ROOT, load_config
from .crops import (
    MODES,
    ROI,
    Crop,
    CropPrediction,
    box_iou,
    global_nms,
    infer_crops,
    make_crops,
)
from .detector import Detection, create_detector
from .image_inference import CSV_FIELDS, _write_json
from .images import annotate_image, detection_record, load_rgb_image
from .person_labels import annotation_box, match_image, new_labels, validate_labels

THRESHOLDS = (0.10, 0.20, 0.30, 0.40, 0.50, 0.55)


def empty_output(path: Path) -> None:
    if path.exists() and (not path.is_dir() or any(path.iterdir())):
        raise ValueError(f"Output must be new or empty; preserving existing results: {path}")
    path.mkdir(parents=True, exist_ok=True)


def save_preview(image: Image.Image, path: Path, banner: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    preview = image.copy()
    preview.thumbnail((1600, 1000))
    draw = ImageDraw.Draw(preview)
    draw.rectangle((0, 0, preview.width, 24), fill="black")
    draw.text((6, 6), banner, fill="white")
    preview.save(path, quality=90)


def crop_preview(image: Image.Image, crops: list[Crop], path: Path, mode: str) -> None:
    overlay = image.copy()
    draw = ImageDraw.Draw(overlay)
    for crop, color in zip(crops, ("cyan", "orange", "lime", "magenta"), strict=False):
        left, top, right, bottom = crop.pixels
        draw.rectangle((left, top, right - 1, bottom - 1), outline=color, width=8)
        draw.text((left + 8, top + 8), crop.name, fill=color, stroke_width=1)
    save_preview(overlay, path, f"{mode}: detection crops only; NOT physical occupancy zones")


def prediction_row(prediction: CropPrediction, filename: str, index: int) -> dict:
    return detection_record(filename, index, prediction.detection, prediction.crop.image_size) | {
        "source_crop": prediction.crop.name,
        "crop_pixels_xyxy": list(prediction.crop.pixels),
        "full_image_size": list(prediction.crop.image_size),
        "local_box_yxyx": list(prediction.local_box),
    }


def select_predictions(rows: list[dict], mode: str, threshold: float, nms_iou: float) -> tuple:
    eligible = [r for r in rows if r["confidence"] >= threshold]
    if mode in ("full", "roi"):
        return eligible, []  # Preserve the single-pass model postprocess behavior.
    predictions = [
        CropPrediction(
            Detection(
                tuple(r[f"{k}_normalized"] for k in ("ymin", "xmin", "ymax", "xmax")),
                r["confidence"],
                r["class_id"],
            ),
            Crop(r["source_crop"], tuple(r["crop_pixels_xyxy"]), tuple(r["full_image_size"])),
            tuple(r["local_box_yxyx"]),
        )
        for r in eligible
    ]
    kept = global_nms(predictions, nms_iou)
    return [eligible[i] for i in kept], [
        r["detection_index"] for i, r in enumerate(eligible) if i not in kept
    ]


def metric_totals(results: list[dict]) -> dict:
    fields = (
        "true_positives",
        "false_positives",
        "false_negatives",
        "partial_actual",
        "partial_matched",
        "partial_seated_actual",
        "partial_seated_matched",
    )
    totals = {key: sum(r[key] for r in results) for key in fields}
    tp, fp, fn = (totals[k] for k in ("true_positives", "false_positives", "false_negatives"))
    totals["precision"] = tp / (tp + fp) if tp + fp else None
    totals["person_recall"] = tp / (tp + fn) if tp + fn else None
    for prefix in ("partial", "partial_seated"):
        totals[f"{prefix}_recall"] = (
            totals[f"{prefix}_matched"] / totals[f"{prefix}_actual"]
            if totals[f"{prefix}_actual"]
            else None
        )
    return totals


def label_output_review(cache: dict, labels: dict) -> dict:
    """Once reviewed, distinguish low-score localization from absent returned localization.

    This per-label search is diagnostic, not one-to-one recall matching. Uncertain
    labels remain identified separately and never enter primary accuracy metrics.
    """
    complete = validate_labels(labels, cache["images"])
    report = {
        "human_labels_complete": complete,
        "matching_iou": cache["settings"]["matching_iou"],
        "result_type": "per_label_raw_output_review",
        "persons": None,
    }
    if not complete:
        report["reason"] = "Human labeling incomplete; no missed-person attribution available"
        return report
    label_images = {i["id"]: i for i in labels["images"]}
    predictions = {i["file_name"]: i for i in cache["images"]}
    persons = []
    for annotation in labels["annotations"]:
        image = label_images[annotation["image_id"]]
        target = annotation_box(annotation, image)
        modes = {}
        for mode in MODES:
            overlaps = []
            for row in predictions[image["file_name"]]["modes"][mode]["person_outputs"]:
                box = tuple(row[f"{k}_normalized"] for k in ("ymin", "xmin", "ymax", "xmax"))
                if box_iou(box, target) >= report["matching_iou"]:
                    overlaps.append(row)
            best = max(overlaps, key=lambda r: r["confidence"], default=None)
            score = best["confidence"] if best else None
            if score is None:
                status = "no_returned_person_box_at_matching_iou"
            elif score < 0.10:
                status = "localized_only_below_0.10"
            elif score < 0.55:
                status = "localized_below_0.55"
            else:
                status = "localized_at_or_above_0.55"
            modes[mode] = {"status": status, "best_overlapping_person_output": best}
        persons.append(
            {
                "annotation_id": annotation["id"],
                "file_name": image["file_name"],
                "attributes": annotation["attributes"],
                "modes": modes,
            }
        )
    report["persons"] = persons
    return report


def review_overlay(
    image: Image.Image, annotations: list[dict], image_info: dict, matched: set | None = None
) -> Image.Image:
    overlay = image.copy()
    draw = ImageDraw.Draw(overlay)
    for a in annotations:
        y0, x0, y1, x1 = annotation_box(a, image_info)
        color = (
            "orange"
            if a["attributes"]["uncertain"]
            else ("lime" if matched is None or a["id"] in matched else "red")
        )
        draw.rectangle(
            (
                x0 * image.width,
                y0 * image.height,
                min(image.width - 1, x1 * image.width),
                min(image.height - 1, y1 * image.height),
            ),
            outline=color,
            width=6,
        )
        draw.text((x0 * image.width, y0 * image.height), f"human {a['id']}", fill=color)
    return overlay


def write_comparisons(cache: dict, labels: dict, input_folder: Path, output: Path) -> dict:
    complete = validate_labels(labels, cache["images"])
    _write_json(output / "ground_truth" / "labels.coco.json", labels)
    _write_json(output / "label_output_review.json", label_output_review(cache, labels))
    label_images = {i["file_name"]: i for i in labels["images"]}
    settings = cache["settings"]
    summary = {
        "status": "completed",
        "result_type": "model_predictions",
        "ground_truth_complete": complete,
        "accuracy_evaluated": complete,
        "images": len(cache["images"]),
        "images_human_reviewed": sum(i["reviewed"] for i in labels["images"]),
        "settings": settings,
        "modes": {},
        "matching": "score-greedy one-to-one certain labels; unmatched predictions "
        "overlapping uncertain labels at matching IoU are ignored",
        "metrics_unavailable_reason": None
        if complete
        else "Human review is incomplete; prediction counts are not accuracy or recall",
        "warnings": [
            "Low scores are not proof of a human",
            "Only returned SSD postprocess slots are observable, not raw anchors",
            "Multiple crops multiply invocations; no Pi timing/resource validation",
            "Detection ROI is independent of physical occupancy zones",
        ],
    }
    count_rows = []
    for mode in MODES:
        reports = {}
        for threshold in THRESHOLDS:
            reports[threshold] = {
                "mode": mode,
                "threshold": threshold,
                "matching_iou": settings["matching_iou"],
                "accuracy_evaluated": complete,
                "images": [],
            }
        for image_info in cache["images"]:
            filename = image_info["file_name"]
            image = load_rgb_image(input_folder / filename).image
            label_image = label_images[filename]
            annotations = [a for a in labels["annotations"] if a["image_id"] == label_image["id"]]
            if mode == "full":
                save_preview(
                    review_overlay(image, annotations, label_image),
                    output / "ground_truth" / "annotated" / f"{filename}.jpg",
                    "HUMAN LABELS: " + ("reviewed" if label_image["reviewed"] else "PENDING"),
                )
                if not complete:
                    save_preview(
                        image,
                        output / "false_negative_review" / "pending" / f"{filename}.jpg",
                        "UNLABELLED REVIEW: no confirmed false-negative classification",
                    )
            raw = image_info["modes"][mode]["person_outputs"]
            for threshold, report in reports.items():
                kept, suppressed = select_predictions(raw, mode, threshold, settings["nms_iou"])
                metrics = (
                    match_image(kept, annotations, label_image, settings["matching_iou"])
                    if complete
                    else None
                )
                entry = {
                    "image_filename": filename,
                    "prediction_count": len(kept),
                    "pre_global_nms_count": sum(r["confidence"] >= threshold for r in raw),
                    "suppressed_detection_indices": suppressed,
                    "metrics": metrics,
                    "detections": kept,
                }
                report["images"].append(entry)
                count_rows.append(
                    {
                        "mode": mode,
                        "threshold": threshold,
                        "image_filename": filename,
                        "detected": len(kept),
                        "actual_certain": metrics["actual_certain"] if complete else "",
                        "actual_uncertain": metrics["actual_uncertain"] if complete else "",
                        "false_positive_count": metrics["false_positives"] if complete else "",
                        "false_negative_count": metrics["false_negatives"] if complete else "",
                    }
                )
                save_preview(
                    annotate_image(image, kept),
                    output / "annotated" / mode / f"{threshold:.2f}" / f"{filename}.jpg",
                    f"PREDICTIONS ONLY: {mode} score >= {threshold:.2f}; {len(kept)} boxes",
                )
                if complete and metrics["false_negatives"]:
                    overlay = review_overlay(
                        annotate_image(image, kept),
                        annotations,
                        label_image,
                        set(metrics["matched_annotation_ids"]),
                    )
                    save_preview(
                        overlay,
                        output
                        / "false_negative_review"
                        / mode
                        / f"{threshold:.2f}"
                        / f"{filename}.jpg",
                        "RED: missed human label; ORANGE: uncertain; GREEN: matched/predicted",
                    )
        summary["modes"][mode] = {}
        for threshold, report in reports.items():
            report["prediction_count"] = sum(i["prediction_count"] for i in report["images"])
            report["images_with_predictions"] = sum(
                i["prediction_count"] > 0 for i in report["images"]
            )
            report["metrics"] = (
                metric_totals([i["metrics"] for i in report["images"]]) if complete else None
            )
            destination = output / "threshold_comparisons" / mode
            destination.mkdir(parents=True, exist_ok=True)
            _write_json(destination / f"threshold_{threshold:.2f}.json", report)
            csv_path = destination / f"threshold_{threshold:.2f}.csv"
            with csv_path.open("w", newline="", encoding="utf-8") as handle:
                writer = csv.DictWriter(
                    handle,
                    fieldnames=CSV_FIELDS
                    + ["source_crop", "crop_pixels_xyxy", "full_image_size", "local_box_yxyx"],
                )
                writer.writeheader()
                for image_result in report["images"]:
                    writer.writerows(image_result["detections"])
            summary["modes"][mode][f"{threshold:.2f}"] = {
                k: report[k] for k in ("prediction_count", "images_with_predictions", "metrics")
            }
    with (output / "per_image_results.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(count_rows[0]))
        writer.writeheader()
        writer.writerows(count_rows)
    _write_json(output / "summary.json", summary)
    review_dir = output / "false_negative_review"
    review_dir.mkdir(exist_ok=True)
    (review_dir / "README.md").write_text(
        "Red boxes mark unmatched certain HUMAN labels at the specified matching IoU.\n"
        if complete
        else "Human labels incomplete. pending/ contains unlabelled review copies only.\n"
        "No image has been classified as a confirmed false negative.\n",
        encoding="utf-8",
    )
    lines = [
        "# Phase 3 diagnostic summary",
        "",
        summary["metrics_unavailable_reason"]
        or "Complete human labels evaluated at the matching IoU below.",
        "",
        f"Matching IoU: {settings['matching_iou']}; global crop NMS IoU: {settings['nms_iou']}.",
        "",
        "| Mode | 0.10 | 0.20 | 0.30 | 0.40 | 0.50 | 0.55 |",
        "| --- | --- | --- | --- | --- | --- | --- |",
    ]
    for mode in MODES:
        lines.append(
            "| "
            + mode
            + " | "
            + " | ".join(
                str(summary["modes"][mode][f"{t:.2f}"]["prediction_count"]) for t in THRESHOLDS
            )
            + " |"
        )
    lines += [
        "",
        "These are prediction counts, not people counts or evidence of improved accuracy.",
        "Raw returned person outputs, including scores below 0.10, are in predictions.json.",
        "See threshold_comparisons/, annotated/, roi_previews/, model_inputs/, ground_truth/",
        "and false_negative_review/. Full/ROI/left_right/overlap use 1/1/2/4 invokes per image.",
        "No production setting was selected automatically.",
    ]
    (output / "diagnostic_summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return summary


def run_diagnostics(args) -> dict:
    config = load_config(args.config)
    roi = ROI(*args.roi)
    make_crops((2, 2), "overlap", roi, args.overlap)  # Validate before allocating or writing.
    if not all(math.isfinite(v) and 0 < v <= 1 for v in (args.nms_iou, args.matching_iou)):
        raise ValueError("NMS/matching IoU must be in (0,1]")
    labels = new_labels(args.input)
    inventory = labels["images"]
    if args.labels:
        labels = json.loads(args.labels.read_text(encoding="utf-8"))
        validate_labels(labels, inventory)
    empty_output(args.output)
    (args.output / "ground_truth").mkdir()
    _write_json(args.output / "ground_truth" / "labels.coco.json", labels)
    cache = {
        "schema_version": 1,
        "status": "initializing",
        "images": [],
        "settings": {
            "roi_xyxy": asdict(roi),
            "overlap_fraction_of_tile": args.overlap,
            "nms_iou": args.nms_iou,
            "matching_iou": args.matching_iou,
            "thresholds": THRESHOLDS,
            "production_threshold": config.detector.confidence_threshold,
            "native_input": [300, 300],
            "resize": "bilinear stretch",
            "input_encoding": config.detector.input_encoding,
            "normalization_applied": config.detector.input_encoding == "normalized_real",
            "single_pass_extra_nms": False,
        },
        "model_sha256": config.detector.sha256,
        "error": None,
    }
    cache_path = args.output / "predictions.json"
    _write_json(cache_path, cache)
    detector = None
    try:
        detector = create_detector(config.detector, backend=args.runtime)
        cache["runtime"] = detector.runtime_info
        cache["allocated_tensors"] = detector.allocated_metadata()
        cache["status"] = "processing"
        for info in inventory:
            loaded = load_rgb_image(args.input / info["file_name"])
            image_info = dict(info, modes={})
            for mode in MODES:
                crops = make_crops(loaded.image.size, mode, roi, args.overlap)
                crop_preview(
                    loaded.image,
                    crops,
                    args.output / "roi_previews" / mode / f"{info['file_name']}.jpg",
                    mode,
                )
                for crop in crops:
                    left, top, right, bottom = crop.pixels
                    native = loaded.image.crop((left, top, right, bottom)).resize(
                        (300, 300), Image.Resampling.BILINEAR
                    )
                    dest = (
                        args.output
                        / "model_inputs"
                        / mode
                        / f"{info['file_name']}__{crop.name}.png"
                    )
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    native.save(dest)
                predictions = infer_crops(detector, loaded.rgb, crops)
                image_info["modes"][mode] = {
                    "crops": [c.metadata() for c in crops],
                    "invocations": len(crops),
                    "person_outputs": [
                        prediction_row(p, info["file_name"], i)
                        for i, p in enumerate(predictions, 1)
                    ],
                }
            cache["images"].append(image_info)
            cache["allocated_tensors"] = detector.allocated_metadata()
            _write_json(cache_path, cache)
            print(f"{info['file_name']}: all four modes invoked", flush=True)
        cache["status"] = "completed"
        _write_json(cache_path, cache)
        return write_comparisons(cache, labels, args.input, args.output)
    except Exception as exc:
        cache.update(status="failed", error=f"{type(exc).__name__}: {exc}")
        if detector:
            cache["allocated_tensors"] = detector.allocated_metadata()
        _write_json(cache_path, cache)
        raise


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run", help="Real model: four modes x six thresholds; allocate once")
    evaluate = sub.add_parser(
        "evaluate", help="Re-evaluate cached outputs after human labeling; no interpreter"
    )
    for command in (run, evaluate):
        command.add_argument("--input", type=Path, required=True)
        command.add_argument("--output", type=Path, required=True, help="New/empty directory")
    run.add_argument("--labels", type=Path)
    evaluate.add_argument("--labels", type=Path, required=True)
    evaluate.add_argument("--predictions", type=Path, required=True)
    run.add_argument("--config", type=Path, default=REPO_ROOT / "config/config.yaml")
    run.add_argument("--runtime", choices=("auto", "tensorflow", "tflite-runtime"), default="auto")
    run.add_argument(
        "--roi",
        nargs=4,
        type=float,
        default=(0, 0.20, 1, 1),
        metavar=("XMIN", "YMIN", "XMAX", "YMAX"),
    )
    run.add_argument("--overlap", type=float, default=0.2)
    run.add_argument("--nms-iou", type=float, default=0.5)
    run.add_argument("--matching-iou", type=float, default=0.5)
    args = parser.parse_args(argv)
    try:
        if args.command == "run":
            result = run_diagnostics(args)
        else:
            cache = json.loads(args.predictions.read_text(encoding="utf-8"))
            if cache.get("status") != "completed" or cache.get("schema_version") != 1:
                raise ValueError("Evaluate requires a completed phase3 predictions cache")
            inventory = new_labels(args.input)
            validate_labels(inventory, cache["images"])
            labels = json.loads(args.labels.read_text(encoding="utf-8"))
            validate_labels(labels, cache["images"])
            empty_output(args.output)
            (args.output / "ground_truth").mkdir()
            _write_json(args.output / "predictions.json", cache)
            result = write_comparisons(cache, labels, args.input, args.output)
        print(json.dumps(result, indent=2, allow_nan=False))
        return 0
    except (OSError, ValueError, RuntimeError) as exc:
        parser.exit(1, f"Diagnostic error: {exc}\n")


if __name__ == "__main__":
    raise SystemExit(main())
