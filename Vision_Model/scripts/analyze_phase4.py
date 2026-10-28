"""Supplement the saved comparison with geometric error analysis and desktop test packages."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from src.crops import box_iou  # noqa: E402
from src.person_labels import annotation_box, source_hash  # noqa: E402
from src.phase3_diagnostics import empty_output  # noqa: E402
from src.phase4_comparison import write_csv, write_json  # noqa: E402


def analyze(comparison: Path, labels_path: Path, output: Path):
    empty_output(output)
    labels = json.loads(labels_path.read_text())
    summary = json.loads((comparison / "summary.json").read_text())
    label_images = {i["file_name"]: i for i in labels["images"]}
    reports = {}
    analysis = {}
    for family in ("ssd", "yolov5n"):
        best = summary[f"best_{family}_f1"]
        report = json.loads(
            (
                comparison / "evaluations" / best["model_id"] / f"{best['threshold']:.2f}.json"
            ).read_text()
        )
        reports[family] = report
        fp_rows = []
        for image in report["images"]:
            info = label_images[image["file_name"]]
            annotations = [a for a in labels["annotations"] if a["image_id"] == info["id"]]
            for index in image["metrics"]["false_positive_prediction_indices"]:
                row = image["predictions"][index]
                box = tuple(row[f"{k}_normalized"] for k in ("ymin", "xmin", "ymax", "xmax"))
                overlaps = [(box_iou(box, annotation_box(a, info)), a["id"]) for a in annotations]
                overlap, aid = max(overlaps, default=(0.0, None))
                fp_rows.append(
                    {
                        "file_name": image["file_name"],
                        "prediction_index": index,
                        "prediction": row,
                        "highest_gt_iou": overlap,
                        "nearest_annotation_id_by_iou": aid,
                        "geometric_status": "duplicate_after_one_to_one_match"
                        if overlap >= 0.5
                        else (
                            "overlaps_label_but_below_matching_iou"
                            if overlap > 0
                            else "no_label_overlap"
                        ),
                    }
                )
        analysis[family] = {
            "model_id": best["model_id"],
            "threshold": best["threshold"],
            "false_positives": fp_rows,
            "fp_geometric_counts": {
                status: sum(r["geometric_status"] == status for r in fp_rows)
                for status in (
                    "duplicate_after_one_to_one_match",
                    "overlaps_label_but_below_matching_iou",
                    "no_label_overlap",
                )
            },
        }
    rows = []
    for info in labels["images"]:
        row = {
            "file_name": info["file_name"],
            "annotated": sum(a["image_id"] == info["id"] for a in labels["annotations"]),
        }
        for family in ("ssd", "yolov5n"):
            image = next(
                i for i in reports[family]["images"] if i["file_name"] == info["file_name"]
            )
            row.update(
                {
                    f"{family}_{k}": image[k]
                    for k in ("true_positives", "false_positives", "false_negatives")
                }
            )
            row[f"{family}_missed_ids"] = image["metrics"]["false_negative_annotation_ids"]
        rows.append(row)
    write_json(output / "error_analysis.json", analysis)
    write_csv(output / "per_image_best.csv", rows)
    cases = list(__import__("csv").DictReader((comparison / "person_cases.csv").open()))
    write_json(
        output / "person_case_overlap.json",
        {
            "both_matched": sum(
                r["ssd_matched"] == "True" and r["yolo_matched"] == "True" for r in cases
            ),
            "ssd_only": sum(
                r["ssd_matched"] == "True" and r["yolo_matched"] == "False" for r in cases
            ),
            "yolo_only": sum(
                r["ssd_matched"] == "False" and r["yolo_matched"] == "True" for r in cases
            ),
            "both_missed": sum(
                r["ssd_matched"] == "False" and r["yolo_matched"] == "False" for r in cases
            ),
        },
    )
    # Test packaging contains no PyTorch, converter or production-control code.
    exports = json.loads((comparison / "exports/export_verification.json").read_text())
    for entry in exports["exports"]:
        size = entry["size"]
        package = output / "deployment_packages" / str(size)
        package.mkdir(parents=True)
        for artifact in entry["artifacts"]:
            if artifact["file"].endswith((".ncnn.param", ".ncnn.bin")):
                source = comparison / "exports" / artifact["file"]
                if source_hash(source) != artifact["sha256"]:
                    raise ValueError("Export hash mismatch before packaging")
                shutil.copyfile(source, package / source.name)
        sample = entry["samples"][0]
        prepared = comparison / "exports" / f"input_{size}_{sample['file_name']}.npy"
        shutil.copyfile(prepared, package / "prepared_input.npy")
        shutil.copyfile(ROOT / "scripts/infer_phase4_ncnn.py", package / "infer_phase4_ncnn.py")
        shutil.copyfile(
            ROOT / "models/experimental/yolov5n/LICENSE.yolov5-v7.0",
            package / "LICENSE.yolov5-v7.0",
        )
        write_json(
            package / "runtime_contract.json",
            {
                "model_id": f"yolov5n_{size}",
                "upstream_revision": exports["source_revision"],
                "upstream_weight_sha256": exports["weight_sha256"],
                "preprocessing": sample["preprocessing"],
                "person_class_id": 0,
                "decoded_output_shape": sample["ncnn"]["shape"],
                "class_names": json.loads(
                    (ROOT / "models/experimental/yolov5n/manifest.json").read_text()
                )["checkpoint_names"],
                "ncnn": "1.0.20250503",
                "pi_validated": False,
                "postprocessing": "best class; objectness*class; >= threshold; "
                "person NMS IoU>0.45; "
                "reverse saved letterbox ratio/pad; continuous coordinates; clip",
                "raw_input": "prepared_input.npy is a desktop-prepared contract probe; "
                "no camera preprocessing is shipped",
            },
        )
        files = [p for p in package.iterdir() if p.is_file()]
        write_json(package / "checksums.json", {p.name: source_hash(p) for p in files})
    # A clean overview leaves threshold details to the accompanying machine-readable table.
    os.environ["MPLCONFIGDIR"] = str((output / ".matplotlib").resolve())
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, axis = plt.subplots(figsize=(9, 6))
    for model_id in sorted({r["model_id"] for r in summary["configurations"]}):
        points = [
            r
            for r in summary["configurations"]
            if r["model_id"] == model_id and r["precision"] is not None
        ]
        axis.plot(
            [r["recall"] for r in points], [r["precision"] for r in points], "o-", label=model_id
        )
    axis.set(
        xlabel="Person recall at IoU >= 0.50",
        ylabel="Precision",
        xlim=(0, 0.35),
        ylim=(0, 1.03),
        title="27 related classroom photographs; thresholds 0.10 to 0.55",
    )
    axis.legend()
    axis.grid(alpha=0.2)
    fig.tight_layout()
    fig.savefig(output / "precision_recall_overview.png", dpi=160)
    plt.close(fig)
    print(json.dumps({k: v["fp_geometric_counts"] for k, v in analysis.items()}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--comparison", type=Path, default=Path("outputs/phase4_model_comparison"))
    parser.add_argument("--labels", type=Path, default=Path("evaluation_baseline/labels.coco.json"))
    parser.add_argument(
        "--output", type=Path, default=Path("outputs/phase4_model_comparison/analysis")
    )
    args = parser.parse_args()
    analyze(args.comparison, args.labels, args.output)


if __name__ == "__main__":
    main()
