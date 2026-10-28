"""Headless Bookworm Picamera2 wrapper; no camera imports during static checks."""

from __future__ import annotations

import time
from dataclasses import dataclass

import numpy as np

from .config import CameraConfig


@dataclass(frozen=True)
class Frame:
    rgb: np.ndarray
    captured_at: float  # monotonic, conservative acquisition-start timestamp


class PiCamera:
    def __init__(self, config: CameraConfig):
        self.config = config
        self._camera = None

    def __enter__(self) -> PiCamera:
        try:
            from libcamera import Transform
            from picamera2 import Picamera2
        except ImportError as exc:
            raise RuntimeError(
                "Install OS python3-picamera2 and use --system-site-packages"
            ) from exc
        self._camera = Picamera2()
        try:
            configuration = self._camera.create_video_configuration(
                # libcamera BGR888 produces RGB byte order for Python arrays.
                main={"size": (self.config.width, self.config.height), "format": "BGR888"},
                transform=Transform(hflip=self.config.hflip, vflip=self.config.vflip),
                controls={"FrameRate": self.config.fps},
                buffer_count=2,
                queue=False,
            )
            self._camera.configure(configuration)
            self._camera.start(show_preview=False)
        except BaseException:
            self._camera.close()
            self._camera = None
            raise
        return self

    def capture(self) -> Frame:
        if self._camera is None:
            raise RuntimeError("Camera is not open")
        # queue=False prevents returning Picamera2's cached previous request.
        # A bounded wait propagates a capture stall as a fault, never a vacant room.
        started = time.monotonic()
        job = self._camera.capture_array("main", wait=False)
        rgb = job.get_result(timeout=self.config.timeout_seconds)
        if rgb.dtype != np.uint8 or rgb.shape != (self.config.height, self.config.width, 3):
            raise RuntimeError(f"Unexpected camera array: {rgb.shape}, {rgb.dtype}")
        return Frame(rgb, started)

    def __exit__(self, exc_type, exc_value, traceback) -> None:
        if self._camera is not None:
            try:
                self._camera.stop()
            finally:
                self._camera.close()
                self._camera = None
