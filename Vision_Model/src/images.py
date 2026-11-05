"""Deterministic disk-image discovery, oriented RGB loading and diagnostic annotation."""

from __future__ import annotations

import math
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageOps, UnidentifiedImageError

from .detector import Detection
from .zones import ZoneMap

IMAGE_EXTENSIONS = frozenset({".jpg", ".jpeg", ".png"})


class UnreadableImageError(ValueError):
    """An individual image could not be decoded; other images may still be processed."""


@dataclass(frozen=True)
class ImageFolder:
    path: Path

    def discover(self) -> list[Path]:
        if not self.path.is_dir():
            raise ValueError(f"Input folder does not exist or is not a directory: {self.path}")
        images = [
            p for p in self.path.iterdir() if p.is_file() and p.suffix.lower() in IMAGE_EXTENSIONS
        ]
        images.sort(key=lambda p: (p.name.casefold(), p.name))
        if not images:
            raise ValueError(f"No JPEG/JPG/PNG images found in: {self.path}")
        return images


@dataclass(frozen=True)
class LoadedImage:
    image: Image.Image
    encoded_size: tuple[int, int]
    exif_orientation: int | None

    @property
    def rgb(self) -> np.ndarray:
        return np.asarray(self.image, dtype=np.uint8)


def load_rgb_image(path: Path) -> LoadedImage:
    try:
        with Image.open(path) as original:
            if original.format not in ("JPEG", "PNG"):
                raise ValueError(f"Unsupported encoded format: {original.format}")
            size = original.size
            orientation = original.getexif().get(274)
            corrected = ImageOps.exif_transpose(original).convert("RGB")
            corrected.load()
            return LoadedImage(corrected, size, orientation)
    except (OSError, ValueError, UnidentifiedImageError, Image.DecompressionBombError) as exc:
        raise UnreadableImageError(f"{path.name}: {type(exc).__name__}: {exc}") from exc


def detection_record(
    filename: str, index: int, detection: Detection, size: tuple[int, int]
) -> dict:
    """Continuous pixel edges in the full-resolution, EXIF-oriented source image."""
    width, height = size
    ymin, xmin, ymax, xmax = detection.box
    if (
        width <= 0
        or height <= 0
        or not all(math.isfinite(v) and 0 <= v <= 1 for v in detection.box)
    ):
        raise ValueError(
            "Coordinate conversion needs a positive image size and normalized finite box"
        )
    if xmin >= xmax or ymin >= ymax:
        raise ValueError("Coordinate conversion needs a positive-area box")
    return {
        "image_filename": filename,
        "detection_index": index,
        "class_name": "person",
        "class_id": detection.class_id,
        "confidence": detection.score,
        "xmin": xmin * width,
        "ymin": ymin * height,
        "xmax": xmax * width,
        "ymax": ymax * height,
        "center_x": (xmin + xmax) / 2 * width,
        "center_y": (ymin + ymax) / 2 * height,
        "xmin_normalized": xmin,
        "ymin_normalized": ymin,
        "xmax_normalized": xmax,
        "ymax_normalized": ymax,
        "center_x_normalized": (xmin + xmax) / 2,
        "center_y_normalized": (ymin + ymax) / 2,
    }


def annotate_image(
    image: Image.Image, records: list[dict], zones: ZoneMap | None = None
) -> Image.Image:
    if getattr(zones, "schema_version", None) == 2:
        from .calibration_preview import render_preview

        boxes = [
            tuple(r[f"{key}_normalized"] for key in ("ymin", "xmin", "ymax", "xmax"))
            for r in records
        ]
        return render_preview(zones, image, boxes)[0]
    annotated = image.copy()
    draw = ImageDraw.Draw(annotated)
    width, height = image.size
    line_width = max(2, round(min(width, height) / 250))
    try:
        font = ImageFont.truetype("arial.ttf", max(14, round(min(width, height) / 60)))
    except OSError:
        font = ImageFont.load_default()

    def label(x: float, y: float, text: str, color: str) -> None:
        bounds = draw.textbbox((0, 0), text, font=font)
        tw, th = bounds[2] - bounds[0] + 8, bounds[3] - bounds[1] + 8
        x, y = max(0, min(x, width - tw)), max(0, min(y, height - th))
        draw.rectangle((x, y, x + tw, y + th), fill="black")
        draw.text((x + 4, y + 4 - bounds[1]), text, fill=color, font=font)

    if zones is not None:
        for zone in zones.zones:
            points = [
                (min(width - 1, x * width), min(height - 1, y * height)) for x, y in zone.polygon
            ]
            draw.line(points + points[:1], fill="orange", width=line_width)
            label(*points[0], f"UNCALIBRATED: {zone.id}", "orange")
        label(0, 0, "UNCALIBRATED ZONES - diagnostic overlay only", "orange")
    for record in records:
        # Machine-readable edges may equal width/height. PIL uses inclusive pixel indices.
        x0 = min(width - 1, max(0, math.floor(record["xmin"])))
        y0 = min(height - 1, max(0, math.floor(record["ymin"])))
        x1 = min(width - 1, max(x0, math.ceil(record["xmax"]) - 1))
        y1 = min(height - 1, max(y0, math.ceil(record["ymax"]) - 1))
        draw.rectangle((x0, y0, x1, y1), outline="lime", width=line_width)
        label(x0, y0, f"person {record['confidence']:.3f}", "lime")
    return annotated
