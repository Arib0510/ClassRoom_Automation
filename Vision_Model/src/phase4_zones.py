"""Optional human physical-zone sidecar and conservative offline binary evaluation."""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path

from .person_labels import source_hash
from .zones import ZONE_IDS

UNKNOWN = "UNKNOWN"


def new_zone_labels(labels: dict, labels_hash: str) -> dict:
    return {
        "schema_version": 1,
        "person_labels_sha256": labels_hash,
        "physical_layout_verified": False,
        "reviewer": "",
        "layout_evidence": "",
        "persons": [
            {
                "annotation_id": a["id"],
                "image_id": a["image_id"],
                "zone": UNKNOWN,
                "reviewer": "",
                "basis": "",
            }
            for a in labels["annotations"]
        ],
        "images": [
            {
                "image_id": i["id"],
                "file_name": i["file_name"],
                "source_sha256": i["source_sha256"],
                "zones": dict.fromkeys(ZONE_IDS, UNKNOWN),
                "reviewer": "",
                "basis": "",
            }
            for i in labels["images"]
        ],
    }


def validate_zone_labels(document: dict, labels: dict, labels_hash: str) -> None:
    if document.get("schema_version") != 1 or document.get("person_labels_sha256") != labels_hash:
        raise ValueError("Zone sidecar must reference the exact human person-label file")
    if type(document.get("physical_layout_verified")) is not bool:
        raise ValueError("Physical verification must be explicit")
    persons, images = document["persons"], document["images"]
    annotations = {a["id"]: a for a in labels["annotations"]}
    expected = {i["id"]: i for i in labels["images"]}
    if len(persons) != len(annotations) or {p["annotation_id"] for p in persons} != set(
        annotations
    ):
        raise ValueError("Zone person inventory mismatch")
    if len(images) != len(expected) or {i["image_id"] for i in images} != set(expected):
        raise ValueError("Zone image inventory mismatch")
    for p in persons:
        if p["image_id"] != annotations[p["annotation_id"]]["image_id"] or p["zone"] not in (
            *ZONE_IDS,
            UNKNOWN,
        ):
            raise ValueError("Invalid physical person assignment")
        if p["zone"] != UNKNOWN and (not p["reviewer"].strip() or not p["basis"].strip()):
            raise ValueError("Known person zone requires a human reviewer and physical basis")
    for image in images:
        ref = expected[image["image_id"]]
        if any(image[k] != ref[k] for k in ("file_name", "source_sha256")):
            raise ValueError("Zone image hash/name mismatch")
        states = image["zones"]
        if set(states) != set(ZONE_IDS) or any(
            v not in ("occupied", "vacant", UNKNOWN) for v in states.values()
        ):
            raise ValueError("Each physical zone needs occupied/vacant/UNKNOWN")
        if any(v != UNKNOWN for v in states.values()) and (
            not image["reviewer"].strip() or not image["basis"].strip()
        ):
            raise ValueError("Known image-zone pairs need explicit human review")
        for p in persons:
            if p["image_id"] != image["image_id"] or p["zone"] == UNKNOWN:
                continue
            if states[p["zone"]] == "vacant":
                raise ValueError("Assigned person contradicts confirmed vacancy")
    if document["physical_layout_verified"] and (
        not document["reviewer"].strip() or not document["layout_evidence"].strip()
    ):
        raise ValueError("Physical layout verification requires a reviewer and evidence")


def binary_zone_metrics(truth: dict, predictions: dict) -> dict:
    """Known GT pairs only; unresolved predictions stay UNKNOWN with explicit coverage.

    Unknown GT is never inferred vacant, even when no person was assigned there.
    An UNKNOWN prediction is neither a false vacancy nor a true negative.
    """
    if (
        truth.get("physical_layout_verified") is not True
        or predictions.get("mapping_physically_verified") is not True
    ):
        raise ValueError("Zone metrics require reliable physical labels AND prediction mapping")
    if not predictions.get("mapping_evidence", "").strip():
        raise ValueError("Prediction mapping requires physical provenance")
    gt = {i["image_id"]: i for i in truth["images"]}
    pred_images = predictions["images"]
    pred = {i["image_id"]: i for i in pred_images}
    if len(pred) != len(pred_images) or set(pred) != set(gt):
        raise ValueError("Zone prediction inventory mismatch")
    counts = {
        z: dict(
            tp=0,
            fp=0,
            fn=0,
            tn=0,
            unknown_gt=0,
            unknown_prediction=0,
            occupied_unknown_prediction=0,
        )
        for z in ZONE_IDS
    }
    for iid, image in gt.items():
        if pred[iid].get("source_sha256") != image["source_sha256"]:
            raise ValueError("Zone predictions must match original image hashes")
        if set(pred[iid]["zones"]) != set(ZONE_IDS) or set(image["zones"]) != set(ZONE_IDS):
            raise ValueError("Exactly four zone states required")
        for zone in ZONE_IDS:
            actual, observed = image["zones"][zone], pred[iid]["zones"][zone]
            if actual not in ("occupied", "vacant", UNKNOWN) or observed not in (
                "occupied",
                "vacant",
                UNKNOWN,
            ):
                raise ValueError("Invalid binary zone state")
            c = counts[zone]
            if actual == UNKNOWN:
                c["unknown_gt"] += 1
            elif observed == UNKNOWN:
                c["unknown_prediction"] += 1
                c["occupied_unknown_prediction"] += actual == "occupied"
            else:
                key = (
                    ("tp" if observed == "occupied" else "fn")
                    if actual == "occupied"
                    else ("fp" if observed == "occupied" else "tn")
                )
                c[key] += 1
    total = {k: sum(c[k] for c in counts.values()) for k in next(iter(counts.values()))}
    for c in [*counts.values(), total]:
        tp, fp, fn = c["tp"], c["fp"], c["fn"]
        c["precision"] = tp / (tp + fp) if tp + fp else None
        c["recall"] = tp / (tp + fn) if tp + fn else None
        c["f1"] = 2 * tp / (2 * tp + fp + fn) if 2 * tp + fp + fn else None
        occupied = tp + fn + c["occupied_unknown_prediction"]
        c["occupied_zone_recall_including_unresolved"] = tp / occupied if occupied else None
        c["false_vacancy_count"], c["false_occupancy_count"] = fn, fp
    return {
        "per_zone": counts,
        "totals": total,
        "scope": "known ground-truth pairs; binary metrics exclude UNKNOWN predictions; "
        "occupied-zone recall including unresolved exposes availability loss",
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("init", "review", "evaluate"))
    parser.add_argument("--labels", type=Path, required=True)
    parser.add_argument("--sidecar", type=Path)
    parser.add_argument("--predictions", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    if args.output.exists():
        raise ValueError("Choose a new output file; existing evidence is preserved")
    labels = json.loads(args.labels.read_text())
    digest = source_hash(args.labels)
    document = (
        new_zone_labels(labels, digest)
        if args.command == "init"
        else json.loads(args.sidecar.read_text())
    )
    if args.command == "review":
        document = copy.deepcopy(document)
        reviewer = input("Human reviewer name: ").strip()
        document["reviewer"] = reviewer
        document["layout_evidence"] = input(
            "Known room/appliance layout evidence (blank = unknown): "
        ).strip()
        document["physical_layout_verified"] = (
            input("Physical layout verified? Type VERIFIED: ") == "VERIFIED"
        )
        for image in document["images"]:
            print(
                image["file_name"], "Use original photo and human-box overlays; UNKNOWN is valid."
            )
            for person in [p for p in document["persons"] if p["image_id"] == image["image_id"]]:
                print("Person", person["annotation_id"], "allowed", (*ZONE_IDS, UNKNOWN))
                person["zone"] = input("Physical zone [UNKNOWN]: ").strip() or UNKNOWN
                person["reviewer"] = reviewer
                person["basis"] = input("Physical assignment basis: ").strip()
            for zone in ZONE_IDS:
                image["zones"][zone] = (
                    input(f"{zone} occupied/vacant/UNKNOWN [UNKNOWN]: ").strip() or UNKNOWN
                )
            image["reviewer"] = reviewer
            image["basis"] = input(
                "Pair review basis, including evidence for any vacancy: "
            ).strip()
    validate_zone_labels(document, labels, digest)
    if args.command == "evaluate":
        document = binary_zone_metrics(document, json.loads(args.predictions.read_text()))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x", encoding="utf-8") as handle:
        json.dump(document, handle, indent=2, allow_nan=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
