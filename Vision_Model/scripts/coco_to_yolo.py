"""Converts COCO JSON format annotations into YOLO txt format."""

import argparse
import json
import os
from pathlib import Path


def convert_coco_to_yolo(coco_json_path: str, labels_output_dir: str):
    coco_path = Path(coco_json_path).resolve()
    if not coco_path.exists():
        raise FileNotFoundError(f"COCO annotations file not found: {coco_path}")

    with open(coco_path, "r", encoding="utf-8") as f:
        data = json.load(f)

    out_dir = Path(labels_output_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    # Map image id to (file_name, width, height)
    images_info = {}
    for img in data.get("images", []):
        images_info[img["id"]] = (
            img["file_name"],
            img.get("width", 640),
            img.get("height", 480),
        )

    # Group annotations by image_id
    annotations_by_img = {}
    for ann in data.get("annotations", []):
        img_id = ann["image_id"]
        annotations_by_img.setdefault(img_id, []).append(ann)

    converted_count = 0
    for img_id, (file_name, img_w, img_h) in images_info.items():
        base_name = os.path.splitext(file_name)[0]
        yolo_lines = []
        for ann in annotations_by_img.get(img_id, []):
            bbox = ann["bbox"]  # [x, y, width, height]
            x, y, w, h = bbox
            x_center = (x + w / 2.0) / float(img_w)
            y_center = (y + h / 2.0) / float(img_h)
            norm_w = w / float(img_w)
            norm_h = h / float(img_h)

            # Clamp [0, 1]
            x_center = max(0.0, min(1.0, x_center))
            y_center = max(0.0, min(1.0, y_center))
            norm_w = max(0.0, min(1.0, norm_w))
            norm_h = max(0.0, min(1.0, norm_h))

            # Class 0: person
            yolo_lines.append(f"0 {x_center:.6f} {y_center:.6f} {norm_w:.6f} {norm_h:.6f}")

        txt_file = out_dir / f"{base_name}.txt"
        txt_file.write_text("\n".join(yolo_lines))
        converted_count += 1

    print(f"[OK] Converted {len(data.get('annotations', []))} annotations across {converted_count} images to: {out_dir}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Convert COCO JSON to YOLO TXT")
    parser.add_argument("--json", required=True, help="Path to COCO JSON annotations")
    parser.add_argument("--output", required=True, help="Output directory for YOLO .txt files")
    args = parser.parse_args()
    convert_coco_to_yolo(args.json, args.output)

