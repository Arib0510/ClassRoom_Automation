"""Reproducible offline comparison; no camera, MQTT, temporal state or actuator entry point."""

from __future__ import annotations

import argparse
import csv
import json
import os
import platform
import sys
from datetime import UTC, datetime
from importlib.metadata import version
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

from .crops import MODES
from .experimental_detector import (
    MODEL_DIR,
    REVISION,
    WEIGHT_SHA256,
    CachedSSD,
    YOLOv5n,
    probability,
)
from .images import load_rgb_image
from .person_labels import match_image, new_labels, source_hash, validate_labels
from .phase3_diagnostics import THRESHOLDS, empty_output
from .phase4_zones import new_zone_labels


def write_json(path: Path, document):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(document, indent=2, allow_nan=False) + "\n", encoding="utf-8")


def write_csv(path: Path, rows: list[dict]):
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def evaluate_configuration(
    images: list[dict], labels: dict, model_id: str, threshold: float
) -> dict:
    probability(threshold)
    if not validate_labels(labels, images):
        raise ValueError("All images require human review before comparison")
    label_images = {i["file_name"]: i for i in labels["images"]}
    per_image = []
    for image in images:
        info = label_images[image["file_name"]]
        annotations = [a for a in labels["annotations"] if a["image_id"] == info["id"]]
        rows = [r for r in image["predictions"] if r["confidence"] >= threshold]
        metrics = match_image(rows, annotations, info, 0.50)
        tp, fp, fn = (metrics[k] for k in ("true_positives", "false_positives", "false_negatives"))
        seated = [
            a for a in annotations if a["attributes"]["seated"] and not a["attributes"]["uncertain"]
        ]
        seated_matched = sum(a["id"] in metrics["matched_annotation_ids"] for a in seated)
        per_image.append(
            {
                "file_name": image["file_name"],
                "model_id": model_id,
                "threshold": threshold,
                "true_positives": tp,
                "false_positives": fp,
                "false_negatives": fn,
                "precision": tp / (tp + fp) if tp + fp else None,
                "recall": tp / (tp + fn) if tp + fn else None,
                "f1": 2 * tp / (2 * tp + fp + fn) if 2 * tp + fp + fn else None,
                "annotated_persons": metrics["actual_certain"],
                "accepted_predictions": len(rows),
                "seated_actual": len(seated),
                "seated_matched": seated_matched,
                "seated_recall": seated_matched / len(seated) if seated else None,
                "metrics": metrics,
                "predictions": rows,
            }
        )
    total_keys = (
        "true_positives",
        "false_positives",
        "false_negatives",
        "annotated_persons",
        "accepted_predictions",
        "seated_actual",
        "seated_matched",
    )
    total = {k: sum(i[k] for i in per_image) for k in total_keys}
    tp, fp, fn = (total[k] for k in ("true_positives", "false_positives", "false_negatives"))
    total.update(
        model_id=model_id,
        threshold=threshold,
        matching_iou=0.5,
        precision=tp / (tp + fp) if tp + fp else None,
        recall=tp / (tp + fn) if tp + fn else None,
        f1=2 * tp / (2 * tp + fp + fn) if 2 * tp + fp + fn else None,
        images_with_detections=sum(bool(i["predictions"]) for i in per_image),
        images_with_missed_people=sum(i["false_negatives"] > 0 for i in per_image),
        seated_recall=total["seated_matched"] / total["seated_actual"]
        if total["seated_actual"]
        else None,
        partial_recall=None,
        partial_seated_recall=None,
        partial_status="NOT AVAILABLE: no positive partial flags",
        images=per_image,
    )
    return total


def annotation_inventory(labels: dict) -> dict:
    annotations = labels["annotations"]
    flags = {
        key: {
            "true": sum(a.get("attributes", {}).get(key) is True for a in annotations),
            "false": sum(a.get("attributes", {}).get(key) is False for a in annotations),
            "missing": [a["id"] for a in annotations if key not in a.get("attributes", {})],
        }
        for key in ("uncertain", "seated", "partial", "distant", "desk_occluded")
    }
    return {
        "images": len(labels["images"]),
        "reviewed_images": sum(i["reviewed"] for i in labels["images"]),
        "certain_persons": sum(not a["attributes"]["uncertain"] for a in annotations),
        "flags": flags,
        "partial_status": "All flags present and false; no partial-positive denominator. "
        "Human confirmation needed to distinguish absent category from under-flagging.",
        "review_needed": [
            {
                "annotation_id": a["id"],
                "image_id": a["image_id"],
                "reason": "Confirm partial:false; add distant/desk_occluded only by human review",
            }
            for a in annotations
        ],
        "multi_person_images": [
            i["file_name"]
            for i in labels["images"]
            if sum(a["image_id"] == i["id"] for a in annotations) > 1
        ],
        "reopen_command": ".\\.venv\\Scripts\\python.exe -m src.annotate_persons "
        "--input sample_images "
        "--labels outputs/phase4_attribute_review/labels.coco.json",
        "review_copy_setup": "Copy-Item evaluation_baseline/labels.coco.json "
        "outputs/phase4_attribute_review/labels.coco.json (create new parent first)",
    }


def overlay(path: Path, info: dict, labels: dict, report: dict, size=(1050, 680)) -> Image.Image:
    image = load_rgb_image(path).image
    original_w, original_h = image.size
    image.thumbnail((size[0], size[1] - 80))
    canvas = Image.new("RGB", size, "#171d28")
    canvas.paste(image, (0, 80))
    draw = ImageDraw.Draw(canvas)
    try:
        font = ImageFont.truetype("arial.ttf", 17)
    except OSError:
        font = ImageFont.load_default()
    draw.text(
        (10, 5),
        f"{report['model_id']} | input "
        f"{300 if report['model_id'].startswith('ssd') else report['model_id'].split('_')[-1]} "
        "square "
        f"| confidence >= {report['threshold']:.2f} | IoU >= 0.50",
        font=font,
        fill="white",
    )
    draw.text(
        (10, 29),
        "GT: cyan matched / red FN | prediction: green TP / orange FP / gray ignored",
        font=font,
        fill="white",
    )
    draw.text(
        (10, 52),
        path.name + " | person class only; no physical zone claims",
        font=font,
        fill="white",
    )
    sx, sy = image.width / original_w, image.height / original_h

    def box(x0, y0, x1, y1, text, color, width, below=False):
        xy = (x0 * sx, y0 * sy + 80, x1 * sx, y1 * sy + 80)
        draw.rectangle(xy, outline=color, width=width)
        x = min(size[0] - 140, max(0, xy[0]))
        y = min(size[1] - 23, max(80, xy[3] if below else xy[1] - 22))
        bounds = draw.textbbox((x, y), text, font=font)
        draw.rectangle(bounds, fill="black")
        draw.text((x, y), text, fill=color, font=font)

    metrics = report["metrics"]
    for annotation in labels["annotations"]:
        if annotation["image_id"] != info["id"]:
            continue
        x, y, w, h = annotation["bbox"]
        matched = annotation["id"] in metrics["matched_annotation_ids"]
        color = "cyan" if matched else "red"
        box(x, y, x + w, y + h, f"GT {annotation['id']} {'matched' if matched else 'FN'}", color, 4)
    for j, row in enumerate(report["predictions"]):
        ignored = j in metrics["uncertain_ignored_prediction_indices"]
        fp = j in metrics["false_positive_prediction_indices"]
        status, color = (
            ("ignored", "gray") if ignored else (("FP", "orange") if fp else ("TP", "lime"))
        )
        box(
            *(row[k] for k in ("xmin", "ymin", "xmax", "ymax")),
            f"person {row['confidence']:.3f} {status}",
            color,
            2,
            True,
        )
    return canvas


def baseline_verification(
    cache: dict, labels: dict, saved: dict, input_dir: Path
) -> tuple[list, dict]:
    reports = []
    checks = []
    for mode in MODES:
        for threshold in THRESHOLDS:
            adapter = CachedSSD(cache, mode, threshold)
            images = [
                dict(i, predictions=adapter.predict(input_dir / i["file_name"])[0])
                for i in cache["images"]
            ]
            report = evaluate_configuration(images, labels, adapter.model_id, threshold)
            previous = saved["modes"][mode][f"{threshold:.2f}"]
            for key in ("true_positives", "false_positives", "false_negatives"):
                if report[key] != previous["metrics"][key]:
                    raise ValueError(f"SSD saved baseline mismatch: {mode}/{threshold}/{key}")
            if report["accepted_predictions"] != previous["prediction_count"]:
                raise ValueError("SSD cached count mismatch")
            checks.append({"mode": mode, "threshold": threshold, "verified": True})
            reports.append(report)
    return reports, {"all_24_configurations_verified": True, "checks": checks}


def run(args) -> dict:
    labels = json.loads(args.labels.read_text())
    inventory = new_labels(args.input)["images"]
    if not validate_labels(labels, inventory):
        raise ValueError("Ground truth is not completely human reviewed")
    cache = json.loads(args.ssd_cache.read_text())
    validate_labels(labels, cache["images"])
    if (
        cache["status"] != "completed"
        or cache["model_sha256"]
        != "3438ee45f33153b1fe6c49e18bcd869ce7c94ef01c485d4eb027eaf8fc0db8ac"
    ):
        raise ValueError("Incomplete or unexpected SSD prediction cache")
    saved = json.loads(args.ssd_summary.read_text())
    reports, verification = baseline_verification(cache, labels, saved, args.input)
    empty_output(args.output)
    write_json(args.output / "baseline_verification.json", verification)
    write_json(args.output / "annotation_completeness.json", annotation_inventory(labels))
    write_json(
        args.output / "zone_labels.pending.json", new_zone_labels(labels, source_hash(args.labels))
    )
    summary = {
        "status": "processing",
        "created_at": datetime.now(UTC).isoformat(),
        "python": sys.version,
        "platform": platform.platform(),
        "device": "cpu",
        "torch_threads": 2,
        "model_revision": REVISION,
        "weight_sha256": WEIGHT_SHA256,
        "images": len(inventory),
        "certain_persons": sum(not a["attributes"]["uncertain"] for a in labels["annotations"]),
        "dataset": inventory,
        "labels_sha256": source_hash(args.labels),
        "ssd_cache_sha256": source_hash(args.ssd_cache),
        "ssd_summary_sha256": source_hash(args.ssd_summary),
        "zone_accuracy": {
            "status": "PENDING",
            "reason": "No reliable physical labels or confirmed camera-zone mapping",
        },
        "software_is_not_hardware_validation": True,
        "configurations": [],
        "inference_invocations": 0,
    }
    write_json(args.output / "summary.json", summary)
    try:
        for size in (320, 416):
            model = YOLOv5n(size, args.model_dir)
            model_cache = {
                "model_id": model.model_id,
                "weight_sha256": WEIGHT_SHA256,
                "source_revision": REVISION,
                "checkpoint_names": model.names,
                "parameters_fused": sum(p.numel() for p in model.model.parameters()),
                "images": [],
                "status": "processing",
            }
            for info in inventory:
                predictions, preprocessing = model.predict(args.input / info["file_name"])
                model_cache["images"].append(
                    dict(info, predictions=predictions, preprocessing=preprocessing)
                )
                raw_dir = args.output / "raw" / model.model_id
                raw_dir.mkdir(parents=True, exist_ok=True)
                np.savez_compressed(
                    raw_dir / f"{info['file_name']}.npz",
                    decoded=model.last_raw,
                    person_candidates=model.last_candidates,
                )
                write_json(args.output / "predictions" / f"{model.model_id}.json", model_cache)
                print(
                    f"{model.model_id}: {len(model_cache['images'])}/{len(inventory)} "
                    f"{info['file_name']}: {len(predictions)} predictions",
                    flush=True,
                )
            model_cache["status"] = "completed"
            model_cache["invocations"] = model.invocations
            write_json(args.output / "predictions" / f"{model.model_id}.json", model_cache)
            summary["inference_invocations"] += model.invocations
            for threshold in THRESHOLDS:
                reports.append(
                    evaluate_configuration(model_cache["images"], labels, model.model_id, threshold)
                )
        summary["dependencies"] = {
            p: version(p)
            for p in ("torch", "torchvision", "numpy", "Pillow", "opencv-python", "PyYAML")
        }
    except Exception as exc:
        summary.update(status="failed", error=f"{type(exc).__name__}: {exc}")
        write_json(args.output / "summary.json", summary)
        raise
    per_image_rows = []
    for report in reports:
        model_id, threshold = report["model_id"], report["threshold"]
        write_json(args.output / "evaluations" / model_id / f"{threshold:.2f}.json", report)
        if model_id.startswith("ssd") and threshold == 0.1:
            write_json(
                args.output / "predictions" / f"{model_id}.json",
                {
                    "model_id": model_id,
                    "source_cache_sha256": summary["ssd_cache_sha256"],
                    "images": [
                        dict(
                            i,
                            predictions=CachedSSD(cache, model_id[4:], 0.0).predict(
                                args.input / i["file_name"]
                            )[0],
                        )
                        for i in cache["images"]
                    ],
                    "note": "All raw crop outputs remain in original cache; "
                    "this view includes global crop NMS",
                },
            )
        for image in report["images"]:
            per_image_rows.append(
                {k: v for k, v in image.items() if k not in ("metrics", "predictions")}
            )
        summary["configurations"].append({k: v for k, v in report.items() if k != "images"})
    write_csv(args.output / "comparison.csv", summary["configurations"])
    write_csv(args.output / "per_image.csv", per_image_rows)
    write_json(args.output / "precision_recall.json", summary["configurations"])
    write_csv(
        args.output / "precision_recall.csv",
        [
            {k: r[k] for k in ("model_id", "threshold", "precision", "recall", "f1")}
            for r in summary["configurations"]
        ],
    )
    for family in ("ssd", "yolov5n"):
        candidates = [r for r in summary["configurations"] if r["model_id"].startswith(family)]
        summary[f"best_{family}_f1"] = max(
            candidates, key=lambda r: (r["f1"] or 0, r["precision"] or 0, r["threshold"])
        )
        summary[f"best_{family}_recall"] = max(
            candidates, key=lambda r: (r["recall"] or 0, r["f1"] or 0, r["threshold"])
        )
    # Render all six configurations at their best F1 threshold, plus a consistent 0.40 view.
    selected = {}
    for model_id in sorted({r["model_id"] for r in reports}):
        options = [r for r in reports if r["model_id"] == model_id]
        best = max(options, key=lambda r: (r["f1"] or 0, r["precision"] or 0, r["threshold"]))
        selected[model_id] = best
        for report in [
            best,
            *[r for r in options if r["threshold"] == 0.4 and best["threshold"] != 0.4],
        ]:
            for image, info in zip(report["images"], labels["images"], strict=True):
                panel = overlay(args.input / image["file_name"], info, labels, image)
                destination = args.output / "annotated" / model_id / f"{report['threshold']:.2f}"
                destination.mkdir(parents=True, exist_ok=True)
                panel.save(destination / f"{image['file_name']}.jpg", quality=92)
    ssd_best = selected[summary["best_ssd_f1"]["model_id"]]
    yolo_best = selected[summary["best_yolov5n_f1"]["model_id"]]
    missed_rows = []
    for index, info in enumerate(labels["images"]):
        panels = [
            overlay(args.input / info["file_name"], info, labels, r["images"][index])
            for r in (ssd_best, yolo_best)
        ]
        combined = Image.new("RGB", (2100, 680))
        for j, panel in enumerate(panels):
            combined.paste(panel, (j * 1050, 0))
        dest = args.output / "side_by_side"
        dest.mkdir(exist_ok=True)
        combined.save(dest / f"{info['file_name']}.jpg", quality=92)
        for a in [a for a in labels["annotations"] if a["image_id"] == info["id"]]:
            missed_rows.append(
                {
                    "file_name": info["file_name"],
                    "annotation_id": a["id"],
                    "seated": a["attributes"]["seated"],
                    "ssd_matched": a["id"]
                    in ssd_best["images"][index]["metrics"]["matched_annotation_ids"],
                    "yolo_matched": a["id"]
                    in yolo_best["images"][index]["metrics"]["matched_annotation_ids"],
                }
            )
    write_csv(args.output / "person_cases.csv", missed_rows)
    return write_final_summary(reports, summary, args.output)


def write_final_summary(reports: list, summary: dict, output: Path) -> dict:
    # Plot only after inference so matplotlib stays out of production and unit environments.
    os.environ["MPLCONFIGDIR"] = str((output / ".matplotlib").resolve())
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, axis = plt.subplots(figsize=(9, 6))
    for model_id in sorted({r["model_id"] for r in reports}):
        points = [r for r in reports if r["model_id"] == model_id and r["precision"] is not None]
        axis.plot(
            [r["recall"] for r in points], [r["precision"] for r in points], "o-", label=model_id
        )
        for r in points:
            axis.annotate(f"{r['threshold']:.2f}", (r["recall"], r["precision"]), fontsize=7)
    axis.set(
        xlabel="Person recall (IoU >= 0.50)",
        ylabel="Precision",
        xlim=(0, 1),
        ylim=(0, 1.02),
        title="27 related classroom photographs; six confidence thresholds",
    )
    axis.legend()
    axis.grid(alpha=0.2)
    fig.tight_layout()
    fig.savefig(output / "precision_recall.png", dpi=160)
    plt.close(fig)
    summary["status"] = "completed"
    write_json(output / "summary.json", summary)
    lines = [
        "# Phase 4 real model comparison",
        "",
        "27 related photographs; score-greedy one-to-one matching at IoU >= 0.50.",
        "",
        "| Configuration | Threshold | TP | FP | FN | Precision | Recall | F1 | Seated recall |",
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    for r in summary["configurations"]:
        precision = f"{r['precision']:.4f}" if r["precision"] is not None else "undefined"
        lines.append(
            f"| {r['model_id']} | {r['threshold']:.2f} | {r['true_positives']} "
            f"| {r['false_positives']} | {r['false_negatives']} | {precision} "
            f"| {r['recall']:.4f} | {r['f1']:.4f} | {r['seated_recall']:.4f} |"
        )
    lines += [
        "",
        "Partial/distant/desk-specific recall: NOT AVAILABLE; see annotation_completeness.json.",
        "Physical zone accuracy: PENDING; every pair in zone_labels.pending.json is UNKNOWN.",
        "Windows accuracy evidence does not establish Pi latency, RAM or the five-second target.",
    ]
    (output / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return summary


def finalize_existing(output: Path):
    """Recover final visualization/summary only, preserving the incomplete status record."""
    summary = json.loads((output / "summary.json").read_text())
    if summary["status"] != "processing" or (output / "summary.pre_finalize.json").exists():
        raise ValueError("Finalization requires a preserved, unfinished comparison")
    reports = [json.loads(p.read_text()) for p in sorted((output / "evaluations").glob("*/*.json"))]
    if len(reports) != 36:
        raise ValueError(
            "All 36 cached evaluation reports required; inference will not be repeated"
        )
    labels = json.loads(Path("evaluation_baseline/labels.coco.json").read_text())
    for model_id in ("yolov5n_320", "yolov5n_416"):
        cache = json.loads((output / "predictions" / f"{model_id}.json").read_text())
        if cache["status"] != "completed" or cache["invocations"] != 27:
            raise ValueError("Incomplete genuine-model cache")
        validate_labels(labels, cache["images"])
    write_json(output / "summary.pre_finalize.json", summary)
    summary["configurations"] = [{k: v for k, v in r.items() if k != "images"} for r in reports]
    summary["inference_invocations"] = 54
    summary["dependencies"] = {
        p: version(p)
        for p in ("torch", "torchvision", "numpy", "Pillow", "opencv-python", "PyYAML")
    }
    for family in ("ssd", "yolov5n"):
        candidates = [r for r in summary["configurations"] if r["model_id"].startswith(family)]
        summary[f"best_{family}_f1"] = max(
            candidates, key=lambda r: (r["f1"] or 0, r["precision"] or 0, r["threshold"])
        )
        summary[f"best_{family}_recall"] = max(
            candidates, key=lambda r: (r["recall"] or 0, r["f1"] or 0, r["threshold"])
        )
    return write_final_summary(reports, summary, output)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=Path("sample_images"))
    parser.add_argument("--labels", type=Path, default=Path("evaluation_baseline/labels.coco.json"))
    parser.add_argument(
        "--ssd-cache", type=Path, default=Path("evaluation_baseline/ssd_run02_predictions.json")
    )
    parser.add_argument(
        "--ssd-summary",
        type=Path,
        default=Path("outputs/phase3_diagnostics/evaluated_run_02/summary.json"),
    )
    parser.add_argument("--model-dir", type=Path, default=MODEL_DIR)
    parser.add_argument("--output", type=Path, default=Path("outputs/phase4_model_comparison"))
    parser.add_argument(
        "--finalize-existing",
        action="store_true",
        help="Finish summary/plot from a complete cache after a rendering failure",
    )
    args = parser.parse_args(argv)
    if args.finalize_existing:
        finalize_existing(args.output)
    else:
        run(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
