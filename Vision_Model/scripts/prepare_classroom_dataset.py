"""Turnkey dataset preparation script for classroom vision model training.

Scans raw images from ../images/ or sample_images/, applies sequence-aware train/val splitting
to avoid adjacent-frame data leakage, and generates YOLO-format dataset structure and data.yaml.
"""

import argparse
import glob
import json
import os
import shutil
from pathlib import Path


def prepare_dataset(
    source_dir: str = "images",
    output_dir: str = "Vision_Model/dataset",
    train_ratio: float = 0.75,
):
    source_path = Path(source_dir).resolve()
    if not source_path.exists():
        # Fallback to root images folder
        source_path = Path("../images").resolve()
    if not source_path.exists():
        raise FileNotFoundError(f"Source image folder '{source_dir}' not found.")

    output_path = Path(output_dir).resolve()
    train_img_dir = output_path / "images" / "train"
    val_img_dir = output_path / "images" / "val"
    train_lbl_dir = output_path / "labels" / "train"
    val_lbl_dir = output_path / "labels" / "val"

    for d in [train_img_dir, val_img_dir, train_lbl_dir, val_lbl_dir]:
        d.mkdir(parents=True, exist_ok=True)

    # Find all clean png/jpg images
    clean_images = sorted(glob.glob(str(source_path / "*_clean.png")))
    if not clean_images:
        clean_images = sorted(glob.glob(str(source_path / "*.png")) + glob.glob(str(source_path / "*.jpg")))
    
    print(f"Found {len(clean_images)} images in {source_path}")

    # Group by capture sequence session to avoid data leakage
    sessions = {}
    for img in clean_images:
        filename = os.path.basename(img)
        # Sequence prefix format: classroom_<session_id>-<frame_num>_clean.png
        prefix = filename.split("-")[0] if "-" in filename else "default"
        sessions.setdefault(prefix, []).append(img)

    print(f"Detected {len(sessions)} distinct recording session(s):")
    for s_name, s_imgs in sessions.items():
        print(f"  • {s_name}: {len(s_imgs)} frames")

    train_files = []
    val_files = []

    # Sequence-aware split: allocate entire sessions to either train or val
    sorted_sessions = sorted(sessions.items(), key=lambda x: len(x[1]), reverse=True)
    total_imgs = len(clean_images)
    current_train = 0

    for s_name, s_imgs in sorted_sessions:
        if current_train == 0 or (current_train + len(s_imgs) <= total_imgs * (train_ratio + 0.1) and len(val_files) == 0):
            train_files.extend(s_imgs)
            current_train += len(s_imgs)
        else:
            val_files.extend(s_imgs)

    if not val_files and len(train_files) > 4:
        # Split last few if only one sequence
        val_files = train_files[-int(len(train_files) * 0.25):]
        train_files = train_files[:-len(val_files)]

    print(f"\nSplit Distribution:")
    print(f"  • Train: {len(train_files)} images ({len(train_files)/total_imgs*100:.1f}%)")
    print(f"  • Val:   {len(val_files)} images ({len(val_files)/total_imgs*100:.1f}%)")

    def copy_split(file_list, target_img_dir, target_lbl_dir):
        for img_path in file_list:
            base_name = os.path.splitext(os.path.basename(img_path))[0]
            # Copy image
            target_img = target_img_dir / os.path.basename(img_path)
            shutil.copy2(img_path, target_img)

            # Check if matching label exists, else create blank or check for annotations
            lbl_candidate = source_path / f"{base_name}.txt"
            target_lbl = target_lbl_dir / f"{base_name}.txt"
            if lbl_candidate.exists():
                shutil.copy2(lbl_candidate, target_lbl)
            else:
                if not target_lbl.exists():
                    target_lbl.write_text("")  # Blank template ready for labels

    copy_split(train_files, train_img_dir, train_lbl_dir)
    copy_split(val_files, val_img_dir, val_lbl_dir)

    # Generate data.yaml
    data_yaml_path = output_path / "data.yaml"
    yaml_content = f"""# Classroom Person Detection Dataset (YOLOv8 / YOLO11)
path: {output_path.as_posix()}
train: images/train
val: images/val

# Single unified person class for high recall on occluded & seated students
names:
  0: person
"""
    data_yaml_path.write_text(yaml_content)
    print(f"\n[OK] Dataset generated at: {output_path}")
    print(f"[OK] Configuration written to: {data_yaml_path}")
    return output_path, data_yaml_path


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Prepare Classroom YOLO Dataset")
    parser.add_argument("--source", default="images", help="Source folder of raw images")
    parser.add_argument("--output", default="Vision_Model/dataset", help="Target dataset folder")
    args = parser.parse_args()
    prepare_dataset(args.source, args.output)
