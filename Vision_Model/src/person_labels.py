"""Human-only COCO person labels and explicit completeness-gated evaluation."""

from __future__ import annotations

import hashlib
import math
from pathlib import Path

from .crops import box_iou
from .images import ImageFolder, load_rgb_image


def source_hash(path: Path) -> str:
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def new_labels(input_folder: Path) -> dict:
    images = []
    for index, path in enumerate(ImageFolder(input_folder).discover(), 1):
        loaded = load_rgb_image(path)
        images.append(
            {
                "id": index,
                "file_name": path.name,
                "width": loaded.image.width,
                "height": loaded.image.height,
                "source_sha256": source_hash(path),
                "reviewed": False,
                "reviewed_by": "",
            }
        )
    return {
        "info": {
            "description": "Visible person boxes; no predictions used as ground truth",
            "annotation_source": "human_manual",
            "coordinates": "COCO pixel xywh in EXIF-oriented full-resolution image",
            "box_policy": "Enclose visible person extent; do not invent hidden body parts",
        },
        "categories": [{"id": 1, "name": "person"}],
        "images": images,
        "annotations": [],
    }


def validate_labels(labels: dict, images: list[dict]) -> bool:
    """Bind labels to the exact dataset and reject malformed/ambiguous annotations.

    COCO category 1 is explicitly human person; model class 0 remains independent.
    False means incomplete, never a claim that empty annotations mean no people.
    """
    if labels.get("info", {}).get("annotation_source") != "human_manual":
        raise ValueError("Labels must declare human_manual annotation_source")
    if labels.get("categories") != [{"id": 1, "name": "person"}]:
        raise ValueError("Labels require the explicit COCO person category 1")
    expected = {image["file_name"]: image for image in images}
    actual = labels.get("images", [])
    if len(actual) != len(expected) or {i["file_name"] for i in actual} != set(expected):
        raise ValueError("Label image inventory differs from prediction dataset")
    ids = {}
    for image in actual:
        if type(image["id"]) is not int or image["id"] in ids:
            raise ValueError("Image IDs must be unique integers")
        reference = expected[image["file_name"]]
        if any(image.get(k) != reference[k] for k in ("width", "height", "source_sha256")):
            raise ValueError(f"Label dimensions/hash mismatch: {image['file_name']}")
        if type(image.get("reviewed")) is not bool:
            raise ValueError("Each image needs an explicit reviewed boolean")
        if image["reviewed"] and not str(image.get("reviewed_by", "")).strip():
            raise ValueError("Reviewed images require a human reviewer name")
        ids[image["id"]] = image
    seen = set()
    for annotation in labels.get("annotations", []):
        aid = annotation.get("id")
        if type(aid) is not int or aid in seen:
            raise ValueError("Annotation IDs must be unique integers")
        seen.add(aid)
        if annotation.get("image_id") not in ids or annotation.get("category_id") != 1:
            raise ValueError("Annotation must reference a known image and person category 1")
        if annotation.get("iscrowd") != 0:
            raise ValueError("Label individual people; crowd boxes are unsupported")
        box = annotation.get("bbox", [])
        if len(box) != 4 or any(
            isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v)
            for v in box
        ):
            raise ValueError("COCO bbox needs finite pixel x,y,width,height")
        x, y, w, h = box
        image = ids[annotation["image_id"]]
        if (
            x < 0
            or y < 0
            or w <= 0
            or h <= 0
            or x + w > image["width"] + 1e-6
            or y + h > image["height"] + 1e-6
        ):
            raise ValueError("Label box must have positive area inside the oriented image")
        attrs = annotation.get("attributes", {})
        if any(type(attrs.get(key)) is not bool for key in ("uncertain", "partial", "seated")):
            raise ValueError("Every person needs boolean uncertain, partial and seated attributes")
    return all(image["reviewed"] for image in actual)


def annotation_box(annotation: dict, image: dict) -> tuple:
    x, y, w, h = annotation["bbox"]
    return (
        y / image["height"],
        x / image["width"],
        (y + h) / image["height"],
        (x + w) / image["width"],
    )


def match_image(predictions: list[dict], annotations: list[dict], image: dict, iou: float) -> dict:
    """Score-greedy one-to-one matching to certain labels, then uncertain-region ignores."""
    if not math.isfinite(iou) or not 0 < iou <= 1:
        raise ValueError("Matching IoU must be in (0,1]")
    certain = [a for a in annotations if not a["attributes"]["uncertain"]]
    uncertain = [a for a in annotations if a["attributes"]["uncertain"]]
    matched = set()
    ignored = []
    false_positives = []
    for index in sorted(range(len(predictions)), key=lambda i: -predictions[i]["confidence"]):
        row = predictions[index]
        box = tuple(row[f"{key}_normalized"] for key in ("ymin", "xmin", "ymax", "xmax"))
        candidates = [
            (box_iou(box, annotation_box(a, image)), a["id"])
            for a in certain
            if a["id"] not in matched
        ]
        best = max(candidates, default=(0.0, None))
        if best[0] >= iou:
            matched.add(best[1])
        elif any(box_iou(box, annotation_box(a, image)) >= iou for a in uncertain):
            ignored.append(index)
        else:
            false_positives.append(index)
    missed = [a["id"] for a in certain if a["id"] not in matched]
    partial = [a for a in certain if a["attributes"]["partial"]]
    seated_partial = [a for a in partial if a["attributes"]["seated"]]
    return {
        "actual_certain": len(certain),
        "actual_uncertain": len(uncertain),
        "detected": len(predictions),
        "true_positives": len(matched),
        "false_positives": len(false_positives),
        "false_negatives": len(missed),
        "false_negative_annotation_ids": missed,
        "matched_annotation_ids": sorted(matched),
        "false_positive_prediction_indices": false_positives,
        "uncertain_ignored_prediction_indices": ignored,
        "partial_actual": len(partial),
        "partial_matched": sum(a["id"] in matched for a in partial),
        "partial_seated_actual": len(seated_partial),
        "partial_seated_matched": sum(a["id"] in matched for a in seated_partial),
    }
