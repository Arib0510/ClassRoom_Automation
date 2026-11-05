"""Lazy Bookworm capture with metadata, orientation and explicit frame identity."""

from __future__ import annotations

import time
import uuid

import numpy as np


class CaptureSource:
    def __init__(self, config, camera=None, *, clock=time.monotonic, boot_clock=None):
        self.config, self.camera, self.clock = config, camera, clock
        self.boot_clock = boot_clock or (lambda: time.clock_gettime(time.CLOCK_BOOTTIME))
        self.session = uuid.uuid4().hex
        self.sequence = 0
        self.previous_sensor = None
        self.superseded_estimate = 0

    def open(self):
        if self.camera is None:
            from libcamera import Transform
            from picamera2 import Picamera2

            self.camera = Picamera2()
            c = self.config.base.camera
            try:
                self.camera.configure(
                    self.camera.create_video_configuration(
                        main={"size": (c.width, c.height), "format": "BGR888"},
                        transform=Transform(hflip=c.hflip, vflip=c.vflip),
                        controls={"FrameRate": c.fps},
                        buffer_count=2,
                        queue=False,
                    )
                )
                self.camera.start(show_preview=False)
            except BaseException:
                self.close()
                raise
        return self

    def capture(self):
        if self.camera is None:
            raise RuntimeError("Camera is not open")
        started = self.clock()
        request = self.camera.capture_request(wait=False).get_result(
            timeout=self.config.base.camera.timeout_seconds
        )
        try:
            rgb = request.make_array("main").copy()
            metadata = request.get_metadata()
        finally:
            request.release()
        ended, boot_now = self.clock(), self.boot_clock()
        c = self.config.base.camera
        if rgb.dtype != np.uint8 or rgb.shape != (c.height, c.width, 3):
            raise RuntimeError("Camera returned unexpected RGB shape/dtype")
        sensor = metadata.get("SensorTimestamp")
        if type(sensor) is not int or sensor <= 0 or sensor > boot_now * 1e9:
            raise RuntimeError("Sensor timestamp missing or incompatible with Linux boot clock")
        sensor_age = boot_now - sensor / 1e9
        if sensor_age >= self.config.base.occupancy.stale_seconds:
            raise RuntimeError("Sensor frame already stale")
        if self.previous_sensor is not None:
            if sensor <= self.previous_sensor:
                raise RuntimeError("Repeated/out-of-order sensor frame")
            skipped = max(0, round((sensor - self.previous_sensor) / 1e9 * c.fps) - 1)
            self.superseded_estimate += skipped
        self.previous_sensor = sensor
        # Sensor age uses boot clock locally, then converts to monotonic domain.
        captured_at = min(started, ended - sensor_age)
        rotation = self.config.data["camera"]["rotation"]
        if rotation:
            rgb = np.ascontiguousarray(np.rot90(rgb, -(rotation // 90)))
        self.sequence += 1
        return {
            "frame_id": f"{self.session}-{self.sequence}",
            "rgb": rgb,
            "captured_at": captured_at,
            "capture_duration_seconds": ended - started,
            "sensor_timestamp_ns": sensor,
            "sensor_age_at_receipt_seconds": sensor_age,
            "superseded_frames_estimate": self.superseded_estimate,
            "timestamp_method": "SensorTimestamp CLOCK_BOOTTIME age translated to monotonic; "
            "min acquisition start",
            "orientation_clockwise": rotation,
            "camera_id": self.config.data["camera"]["id"],
            "pose_id": self.config.data["camera"]["pose_id"],
        }

    def close(self):
        if self.camera is not None:
            try:
                self.camera.stop()
            finally:
                self.camera.close()
                self.camera = None


class ImageSource:
    """Offline source using the same oriented RGB loader; never a mounted-camera claim."""

    def __init__(self, paths, clock=time.monotonic):
        self.paths, self.clock = iter(paths), clock
        self.sequence = 0

    def capture(self):
        from .images import load_rgb_image

        path = next(self.paths)
        started = self.clock()
        image = load_rgb_image(path)
        self.sequence += 1
        return {
            "frame_id": f"image-{self.sequence}",
            "rgb": image.rgb,
            "captured_at": started,
            "capture_duration_seconds": self.clock() - started,
            "source_file": str(path),
            "source_kind": "offline_image",
        }

    def close(self):
        pass
