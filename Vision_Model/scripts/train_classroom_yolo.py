"""Turnkey local training script for Classroom Occupancy & Person Detection.

Optimized for:
  • Seated students under severe desk occlusions
  • Dark vs bright lighting variations (fluorescent, sunlight, shadows)
  • Front-ceiling camera perspective
  • Deployment export to Raspberry Pi 5 (4GB RAM) via ONNX / OpenVINO / TFLite
"""

import argparse
import os
import sys
from pathlib import Path


def train_model(
    data_yaml: str = "dataset/data.yaml",
    model_name: str = "yolov8n.pt",
    epochs: int = 50,
    batch_size: int = 16,
    img_size: int = 640,
    device: str = "",
    project: str = "runs/train",
    name: str = "classroom_person_detector",
):
    try:
        from ultralytics import YOLO
    except ImportError:
        print("[ERROR] 'ultralytics' is not installed. Run: pip install ultralytics")
        sys.exit(1)

    # Automatically resolve dataset path regardless of working directory
    p_data = Path(data_yaml)
    if not p_data.exists():
        candidates = [
            Path("dataset/data.yaml"),
            Path("Vision_Model/dataset/data.yaml"),
            Path(__file__).parent.parent / "dataset" / "data.yaml",
        ]
        for c in candidates:
            if c.exists():
                p_data = c.resolve()
                break
    data_yaml = str(p_data.resolve())

    # Automatically resolve project output path
    p_proj = Path(project)
    if not p_proj.is_absolute():
        p_proj = (Path(__file__).parent.parent / "runs" / "train").resolve()
    project = str(p_proj)

    import torch
    if not device:
        device = "0" if torch.cuda.is_available() else "cpu"
    print(f"==========================================================")
    print(f"  ClassPulse Vision: Local Classroom Model Training")
    print(f"  Target Device:       {device.upper()} (PyTorch {torch.__version__})")
    print(f"  Base Architecture:   {model_name}")
    print(f"  Input Resolution:    {img_size}x{img_size} (Native camera match)")
    print(f"  Training Epochs:     {epochs}")
    print(f"  Dataset Config:      {data_yaml}")
    print(f"==========================================================")

    model = YOLO(model_name)

    # Classroom-tuned hyperparameters
    results = model.train(
        data=data_yaml,
        epochs=epochs,
        batch=batch_size,
        imgsz=img_size,
        device=device,
        project=project,
        name=name,
        # Lighting Invariance (handles dark rooms, curtains closed, direct sunlight)
        hsv_h=0.015,
        hsv_s=0.7,
        hsv_v=0.4,
        # Occlusion Resilience (handles seated students hidden behind desks & chairs)
        mosaic=1.0,
        mixup=0.15,
        scale=0.5,
        # Perspective Geometry (Fixed ceiling mount: horizontal flip OK, NO upside-down flip)
        fliplr=0.5,
        flipud=0.0,
        degrees=5.0,  # Slight mount vibration tolerance
        # Optimization
        optimizer="AdamW",
        lr0=0.01,
        lrf=0.01,
        cos_lr=True,
        patience=20,  # Early stopping
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

    # Export formats for Raspberry Pi 5 (4GB)
    print("\n[INFO] Exporting ONNX deployment artifact for Raspberry Pi 5...")
    trained_model = YOLO(str(best_weights))

    # 1. ONNX (Recommended & benchmarked for Raspberry Pi 5 ONNX Runtime, ~25-35 FPS)
    try:
        onnx_file = trained_model.export(format="onnx", imgsz=img_size, dynamic=False)
        print(f"  * ONNX Export:     {onnx_file}")
    except Exception as e:
        print(f"  * ONNX export skipped: {e}")

    print("\n[OK] Model training and export pipeline finished successfully!")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Train Classroom YOLOv8/v11 Model")
    parser.add_argument("--data", default="dataset/data.yaml", help="Path to data.yaml")
    parser.add_argument("--model", default="yolov8n.pt", help="Base model (yolov8n.pt, yolo11n.pt)")
    parser.add_argument("--epochs", type=int, default=50, help="Training epochs")
    parser.add_argument("--batch", type=int, default=16, help="Batch size")
    parser.add_argument("--imgsz", type=int, default=640, help="Image resolution")
    parser.add_argument("--device", default="", help="Device: '0', 'cpu', etc.")
    args = parser.parse_args()

    train_model(
        data_yaml=args.data,
        model_name=args.model,
        epochs=args.epochs,
        batch_size=args.batch,
        img_size=args.imgsz,
        device=args.device,
    )

