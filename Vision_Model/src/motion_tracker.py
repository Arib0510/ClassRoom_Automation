"""Classroom Moving Object Detection & Tracking Engine.

Architecture:
  1. FastMotionFilter:
     Lightweight frame-differencing filter (<2ms on Pi 5 CPU) using pure NumPy.
     Gates neural detector when room is completely motionless, saving power and thermal budget.
  2. ObjectMotionTracker:
     Associates person detections across consecutive frames via IoU & centroid matching.
     Computes velocity vectors and classifies each person as 'MOVING' vs 'STATIONARY'.
     Maps tracked persons to physical classroom quadrants.
"""

from __future__ import annotations

import math
import time
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

import numpy as np


@dataclass
class TrackedPerson:
    track_id: int
    bbox: Tuple[float, float, float, float]  # (x1, y1, x2, y2) normalized [0, 1]
    centroid: Tuple[float, float]             # (cx, cy)
    velocity: Tuple[float, float] = (0.0, 0.0)  # (vx, vy) in normalized units/second
    speed: float = 0.0                        # ||velocity||
    state: str = "STATIONARY"                 # "MOVING" or "STATIONARY"
    zone: Optional[str] = None               # Assigned classroom quadrant
    last_seen_time: float = 0.0
    frames_tracked: int = 1
    missed_frames: int = 0


class FastMotionFilter:
    """Pre-filter detecting pixel-level motion across consecutive frames."""

    def __init__(self, threshold: int = 25, min_motion_pixels: int = 150):
        self.threshold = threshold
        self.min_motion_pixels = min_motion_pixels
        self.last_gray: Optional[np.ndarray] = None

    def check_motion(self, rgb_frame: np.ndarray) -> Tuple[bool, float, Optional[np.ndarray]]:
        """
        Calculates frame difference.
        Returns: (has_motion, motion_ratio, motion_mask)
        """
        if rgb_frame.ndim == 3 and rgb_frame.shape[2] == 3:
            # Fast integer grayscale conversion: 0.299 R + 0.587 G + 0.114 B
            gray = (
                rgb_frame[:, :, 0].astype(np.uint16) * 77
                + rgb_frame[:, :, 1].astype(np.uint16) * 150
                + rgb_frame[:, :, 2].astype(np.uint16) * 29
            ) >> 8
            gray = gray.astype(np.uint8)
        else:
            gray = rgb_frame

        # Downsample to 160x120 for sub-millisecond motion check
        h, w = gray.shape[:2]
        down_h, down_w = max(1, h // 4), max(1, w // 4)
        small_gray = gray[::4, ::4]

        if self.last_gray is None or self.last_gray.shape != small_gray.shape:
            self.last_gray = small_gray
            return True, 1.0, None  # First frame triggers detection

        diff = np.abs(small_gray.astype(np.int16) - self.last_gray.astype(np.int16))
        motion_mask = (diff > self.threshold).astype(np.uint8)
        changed_pixels = int(np.sum(motion_mask))
        total_pixels = small_gray.size
        ratio = changed_pixels / total_pixels

        self.last_gray = small_gray
        has_motion = changed_pixels >= (self.min_motion_pixels // 16)
        return has_motion, ratio, motion_mask


class ObjectMotionTracker:
    """Multi-object tracker with velocity estimation and motion classification."""

    def __init__(
        self,
        iou_threshold: float = 0.25,
        max_missed_frames: int = 5,
        motion_speed_threshold: float = 0.04,  # Normalized units / second
        smoothing_factor: float = 0.6,
    ):
        self.iou_threshold = iou_threshold
        self.max_missed_frames = max_missed_frames
        self.motion_speed_threshold = motion_speed_threshold
        self.smoothing = smoothing_factor

        self.tracks: Dict[int, TrackedPerson] = {}
        self.next_track_id: int = 1
        self.last_update_time: Optional[float] = None

    @staticmethod
    def _compute_iou(box_a: Tuple[float, float, float, float], box_b: Tuple[float, float, float, float]) -> float:
        xa1, ya1, xa2, ya2 = box_a
        xb1, yb1, xb2, yb2 = box_b

        inter_x1 = max(xa1, xb1)
        inter_y1 = max(ya1, yb1)
        inter_x2 = min(xa2, xb2)
        inter_y2 = min(ya2, yb2)

        if inter_x2 <= inter_x1 or inter_y2 <= inter_y1:
            return 0.0

        inter_area = (inter_x2 - inter_x1) * (inter_y2 - inter_y1)
        area_a = (xa2 - xa1) * (ya2 - ya1)
        area_b = (xb2 - xb1) * (yb2 - yb1)
        union_area = area_a + area_b - inter_area
        return inter_area / union_area if union_area > 0 else 0.0

    @staticmethod
    def _centroid(box: Tuple[float, float, float, float]) -> Tuple[float, float]:
        return ((box[0] + box[2]) / 2.0, (box[1] + box[3]) / 2.0)

    def update(
        self,
        detections: List[Tuple[float, float, float, float]],
        now: Optional[float] = None,
        zone_classifier=None,
    ) -> List[TrackedPerson]:
        """
        Update tracker with new person bounding boxes: [(x1, y1, x2, y2), ...]
        Detections are normalized [0, 1].
        """
        now = time.monotonic() if now is None else float(now)
        dt = (now - self.last_update_time) if self.last_update_time is not None else 0.1
        dt = max(0.01, min(dt, 2.0))  # Clamp dt
        self.last_update_time = now

        unmatched_dets = set(range(len(detections)))
        unmatched_tracks = set(self.tracks.keys())
        matched_pairs: List[Tuple[int, int]] = []

        # Greedy IoU matching
        if self.tracks and detections:
            track_ids = list(self.tracks.keys())
            iou_matrix = np.zeros((len(track_ids), len(detections)), dtype=np.float32)
            for i, tid in enumerate(track_ids):
                for j, det in enumerate(detections):
                    iou_matrix[i, j] = self._compute_iou(self.tracks[tid].bbox, det)

            while True:
                max_iou = np.max(iou_matrix) if iou_matrix.size > 0 else 0.0
                if max_iou < self.iou_threshold:
                    break
                row, col = np.unravel_index(np.argmax(iou_matrix), iou_matrix.shape)
                tid = track_ids[row]
                matched_pairs.append((tid, col))
                unmatched_tracks.discard(tid)
                unmatched_dets.discard(col)
                # Suppress matched row and col
                iou_matrix[row, :] = -1.0
                iou_matrix[:, col] = -1.0

        # Update matched tracks
        for tid, det_idx in matched_pairs:
            det_box = detections[det_idx]
            new_c = self._centroid(det_box)
            old_c = self.tracks[tid].centroid

            # Velocity vector in normalized units / second
            raw_vx = (new_c[0] - old_c[0]) / dt
            raw_vy = (new_c[1] - old_c[1]) / dt

            # Exponential smoothing
            old_vx, old_vy = self.tracks[tid].velocity
            vx = self.smoothing * old_vx + (1.0 - self.smoothing) * raw_vx
            vy = self.smoothing * old_vy + (1.0 - self.smoothing) * raw_vy
            speed = math.hypot(vx, vy)

            # Classify state
            state = "MOVING" if speed > self.motion_speed_threshold else "STATIONARY"
            zone = zone_classifier(new_c) if zone_classifier else self.classify_quadrant(new_c)

            self.tracks[tid].bbox = det_box
            self.tracks[tid].centroid = new_c
            self.tracks[tid].velocity = (vx, vy)
            self.tracks[tid].speed = speed
            self.tracks[tid].state = state
            self.tracks[tid].zone = zone
            self.tracks[tid].last_seen_time = now
            self.tracks[tid].frames_tracked += 1
            self.tracks[tid].missed_frames = 0

        # Age unmatched tracks
        for tid in list(unmatched_tracks):
            self.tracks[tid].missed_frames += 1
            if self.tracks[tid].missed_frames > self.max_missed_frames:
                del self.tracks[tid]

        # Create new tracks for unmatched detections
        for det_idx in unmatched_dets:
            det_box = detections[det_idx]
            c = self._centroid(det_box)
            zone = zone_classifier(c) if zone_classifier else self.classify_quadrant(c)
            new_person = TrackedPerson(
                track_id=self.next_track_id,
                bbox=det_box,
                centroid=c,
                velocity=(0.0, 0.0),
                speed=0.0,
                state="STATIONARY",
                zone=zone,
                last_seen_time=now,
                frames_tracked=1,
                missed_frames=0,
            )
            self.tracks[self.next_track_id] = new_person
            self.next_track_id += 1

        return list(self.tracks.values())

    @staticmethod
    def classify_quadrant(centroid: Tuple[float, float]) -> str:
        """Default quadrant classifier: front_left, front_right, back_left, back_right."""
        cx, cy = centroid
        is_front = cy < 0.5
        is_left = cx < 0.5
        if is_front and is_left:
            return "front_left"
        elif is_front and not is_left:
            return "front_right"
        elif not is_front and is_left:
            return "back_left"
        else:
            return "back_right"
