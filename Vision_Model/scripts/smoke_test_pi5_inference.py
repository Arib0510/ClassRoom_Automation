#!/usr/bin/env python3
"""Load the packaged model and run CPU inference on a synthetic image only."""
from __future__ import annotations

import hashlib
from pathlib import Path

import numpy as np
import torch
from ultralytics import YOLO

ROOT = Path(__file__).resolve().parents[1]
MODEL = ROOT / "models/classroom_yolo_best.pt"
EXPECTED_SHA256 = "25c22208ac714cc571204c7b39f58b460bb01e9b18e59fab7033fce6c06a928c"


def main() -> int:
    if hashlib.sha256(MODEL.read_bytes()).hexdigest() != EXPECTED_SHA256:
        raise SystemExit("FAIL packaged trained model checksum changed")

    # Exercise the NumPy 2.x bridge used by OpenCV frames and torch tensors.
    frame = np.zeros((480, 640, 3), dtype=np.uint8)
    tensor = torch.from_numpy(frame)
    if tuple(tensor.shape) != (480, 640, 3) or tensor.dtype != torch.uint8:
        raise SystemExit("FAIL NumPy uint8 frame to PyTorch tensor conversion")
    if not np.array_equal(tensor.numpy(), frame):
        raise SystemExit("FAIL PyTorch tensor to NumPy round trip")

    model = YOLO(str(MODEL))
    result = model.predict(
        source=frame,
        imgsz=640,
        conf=0.28,
        device="cpu",
        verbose=False,
    )[0]
    if result.orig_shape != (480, 640):
        raise SystemExit(f"FAIL synthetic image dimensions returned as {result.orig_shape}")
    print(
        "PASS packaged model loaded; synthetic CPU inference completed; "
        f"NumPy {np.__version__} -> torch {torch.__version__}; "
        "camera unopened; MQTT untouched"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
