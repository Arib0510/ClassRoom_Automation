"""Turnkey local training script for Classroom Occupancy & Person Detection.

Optimized for:
  • Seated students under severe desk occlusions (Pi_5_Images dataset)
  • Dark vs bright lighting variations (fluorescent, sunlight, shadows)
  • Front-ceiling camera perspective (4:3 640x480 / 1920x1440 framing)
  • Stable fine-tuning with frozen CSPDarknet backbone (freeze=10, lr0=0.0005)
  • Deployment export to Raspberry Pi 5 (4GB RAM) via PyTorch (.pt) & ONNX (.onnx)
"""

from __future__ import annotations

import argparse
import hashlib
import shutil
import sys
from pathlib import Path


def _sha256(path: Path) -> str:
    with path.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def train_model(
    data_yaml: str = "dataset/data.yaml",
    source_images: str = "../Pi_5_Images",
    model_name: str = "yolov8n.pt",
    epochs: int = 12,
    batch_size: int = 16,
    img_size: int = 640,
    freeze_layers: int = 10,
    lr0: float = 0.0005,
    device: str = "",
    project: str = "runs/train",
    name: str = "classroom_person_detector",
):
    try:
        import torch
        from ultralytics import YOLO
    except ImportError:
        print("[ERROR] 'ultralytics' or 'torch' is not installed. Run: pip install ultralytics")
        sys.exit(1)

    vision_root = Path(__file__).resolve().parent.parent

    # Automatically resolve or prepare dataset from Pi_5_Images if needed
    p_data = Path(data_yaml)
    if not p_data.exists():
        candidates = [
            vision_root / "dataset" / "data.yaml",
            Path("Vision_Model/dataset/data.yaml"),
            Path("dataset/data.yaml"),
        ]
        for c in candidates:
            if c.exists():
                p_data = c.resolve()
                break

    train_img_dir = vision_root / "dataset" / "images" / "train"
    if not p_data.exists() or not train_img_dir.exists() or not any(train_img_dir.iterdir()):
        print("[INFO] Preparing classroom dataset from Pi_5_Images automatically...")
        from prepare_classroom_dataset import prepare_dataset

        src_dir = Path(source_images)
        if not src_dir.exists():
            src_dir = vision_root.parent / "Pi_5_Images"
        prepare_dataset(
            source_dir=str(src_dir),
            output_dir=str(vision_root / "dataset"),
            auto_label=True,
            teacher_model=str(vision_root / "yolov8n.pt"),
        )
        p_data = (vision_root / "dataset" / "data.yaml").resolve()
    else:
        p_data = p_data.resolve()

    data_yaml = str(p_data)

    # Resolve base model weights
    p_model = Path(model_name)
    if not p_model.exists():
        candidate_model = vision_root / model_name
        if candidate_model.exists():
            p_model = candidate_model.resolve()
    model_name = str(p_model)

    # Resolve project output path
    p_proj = Path(project)
    if not p_proj.is_absolute():
        p_proj = (vision_root / "runs" / "train").resolve()
    project = str(p_proj)

    if not device:
        device = "0" if torch.cuda.is_available() else "cpu"

    print("==========================================================")
    print("  ClassPulse Vision: Automated Pi 5 Classroom Training")
    print(f"  Target Device:       {device.upper()} (PyTorch {torch.__version__})")
    print(f"  Base Architecture:   {model_name}")
    print(f"  Input Resolution:    {img_size} (4:3 Rectangular Training)")
    print(f"  Training Epochs:     {epochs} (Frozen Backbone Layers: {freeze_layers})")
    print(f"  Learning Rate (lr0): {lr0} (AdamW Stable Fine-Tuning)")
    print(f"  Dataset Config:      {data_yaml}")
    print("==========================================================")

    model = YOLO(model_name)

    # Classroom-tuned hyperparameters with frozen backbone to prevent weight divergence
    model.train(
        data=data_yaml,
        epochs=epochs,
        batch=batch_size,
        imgsz=img_size,
        rect=True,
        freeze=freeze_layers,
        device=device,
        workers=0 if sys.platform.startswith("win") else 4,
        project=project,
        name=name,
        # Lighting Invariance (fluorescent, indoor, daylight, shadows)
        hsv_h=0.012,
        hsv_s=0.5,
        hsv_v=0.35,
        # Occlusion Resilience (seated students behind desks)
        mosaic=0.0,  # Disabled with rect=True to preserve true ceiling perspective & aspect ratio
        mixup=0.0,
        scale=0.25,
        translate=0.08,
        # Perspective Geometry (Fixed ceiling mount: horizontal flip OK, NO upside-down flip)
        fliplr=0.5,
        flipud=0.0,
        degrees=3.0,
        # Stable Fine-Tuning Optimization
        optimizer="AdamW",
        lr0=lr0,
        lrf=0.05,
        warmup_epochs=2.0,
        weight_decay=0.0005,
        cos_lr=True,
        patience=10,
        save=True,
        plots=True,
        exist_ok=True,
    )

    save_dir = Path(model.trainer.save_dir) if hasattr(model, "trainer") and model.trainer else Path(project) / name
    best_weights = save_dir / "weights" / "best.pt"
    if not best_weights.exists():
        last_weights = save_dir / "weights" / "last.pt"
        if last_weights.exists():
            best_weights = last_weights

    print(f"\n[OK] Training complete! Best weights saved to: {best_weights}")

    # Copy best weights to canonical deployment locations in Vision_Model/models/ and Vision_Model/
    models_dir = vision_root / "models"
    models_dir.mkdir(parents=True, exist_ok=True)
    deployed_pt = models_dir / "classroom_yolo_best.pt"
    root_deployed_pt = vision_root / "yolov8n_classroom.pt"

    if best_weights.exists():
        shutil.copy2(best_weights, deployed_pt)
        shutil.copy2(best_weights, root_deployed_pt)
        pt_hash = _sha256(deployed_pt)
        print(f"  * Deployed PT Model:   {deployed_pt} (SHA256: {pt_hash[:16]}...)")

    # Export ONNX for Raspberry Pi 5 (4GB RAM) high-FPS inference
    print("\n[INFO] Exporting ONNX deployment artifact for Raspberry Pi 5 (4GB)...")
    trained_model = YOLO(str(best_weights))
    try:
        onnx_file = trained_model.export(
            format="onnx",
            imgsz=(480, 640),
            opset=12,
            simplify=True,
            dynamic=False,
        )
        onnx_path = Path(onnx_file)
        if onnx_path.exists():
            deployed_onnx = models_dir / "classroom_yolo_best.onnx"
            shutil.copy2(onnx_path, deployed_onnx)
            onnx_hash = _sha256(deployed_onnx)
            print(f"  * ONNX Export:         {deployed_onnx} (SHA256: {onnx_hash[:16]}...)")
    except Exception as e:
        print(f"  * ONNX export warning: {e}")

    print("\n[OK] Model training and Raspberry Pi 5 export pipeline finished successfully!")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Train Classroom YOLOv8 Model on Pi_5_Images")
    parser.add_argument("--data", default="dataset/data.yaml", help="Path to data.yaml")
    parser.add_argument("--source", default="../Pi_5_Images", help="Raw images folder if dataset needs prep")
    parser.add_argument("--model", default="yolov8n.pt", help="Base model (yolov8n.pt)")
    parser.add_argument("--epochs", type=int, default=12, help="Training epochs (default: 12)")
    parser.add_argument("--batch", type=int, default=16, help="Batch size (default: 16)")
    parser.add_argument("--imgsz", type=int, default=640, help="Image resolution (default: 640)")
    parser.add_argument("--freeze", type=int, default=10, help="Frozen backbone layers (default: 10)")
    parser.add_argument("--lr0", type=float, default=0.0005, help="Initial learning rate (default: 0.0005)")
    parser.add_argument("--device", default="", help="Device: '0', 'cpu', etc.")
    args = parser.parse_args()

    train_model(
        data_yaml=args.data,
        source_images=args.source,
        model_name=args.model,
        epochs=args.epochs,
        batch_size=args.batch,
        img_size=args.imgsz,
        freeze_layers=args.freeze,
        lr0=args.lr0,
        device=args.device,
    )
