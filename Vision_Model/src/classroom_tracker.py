"""Lightweight lifecycle tracker used by the Raspberry Pi 5 classroom runtime."""

from __future__ import annotations

import math
import time
from dataclasses import dataclass

Box = tuple[float, float, float, float]
Detection = tuple[Box, float]


@dataclass
class TrackedPerson:
    track_id: int
    bbox: Box
    centroid: tuple[float, float]
    anchor: tuple[float, float]
    zone6: str
    confidence: float = 0.50
    velocity: tuple[float, float] = (0.0, 0.0)
    speed: float = 0.0
    state: str = "STATIONARY"
    zone: str = "front_left"
    is_front: bool = True
    last_seen_time: float = 0.0  # Monotonic time of the most recent observation.
    frames_tracked: int = 1
    missed_frames: int = 0  # Diagnostic only; expiry is elapsed-time based.
    lifecycle: str = "TENTATIVE"  # TENTATIVE, CONFIRMED, RETAINED, EXPIRED.
    confirmation_hits: int = 1
    current_frame_observed: bool = True


class ClassroomMotionTracker:
    """One-to-one IoU tracker with confirmation and elapsed-time retention.

    ``RETAINED`` is a confirmed track that was not observed in the current frame.
    It is useful for a short occupancy hold but is deliberately excluded from
    current-frame counts by the runtime.
    """

    def __init__(
        self,
        iou_threshold: float = 0.18,
        centroid_distance_thresh: float = 0.06,
        max_missed_frames: int = 14,
        max_age_seconds: float = 1.5,
        confirmation_hits: int = 2,
        motion_speed_threshold: float = 0.035,
        smoothing_factor: float = 0.6,
        split_y: float = 0.50,
        col_left_x: float = 0.34,
        col_right_x: float = 0.66,
        invert_zones: bool = False,
    ):
        if not 0 <= iou_threshold <= 1:
            raise ValueError("iou_threshold must be in [0,1]")
        if centroid_distance_thresh < 0 or not math.isfinite(centroid_distance_thresh):
            raise ValueError("centroid_distance_thresh must be finite and nonnegative")
        if max_age_seconds <= 0 or not math.isfinite(max_age_seconds):
            raise ValueError("max_age_seconds must be finite and positive")
        if confirmation_hits < 2:
            raise ValueError("confirmation_hits must be at least 2")
        if not 0 < smoothing_factor <= 1:
            raise ValueError("smoothing_factor must be in (0,1]")
        if not 0 <= col_left_x < col_right_x <= 1:
            raise ValueError("zone column boundaries must satisfy 0 <= left < right <= 1")

        self.iou_threshold = float(iou_threshold)
        self.dist_thresh = float(centroid_distance_thresh)
        self.max_missed_frames = int(max_missed_frames)  # Kept as a diagnostic setting.
        self.max_age_seconds = float(max_age_seconds)
        self.confirmation_hits_required = int(confirmation_hits)
        self.motion_speed_threshold = float(motion_speed_threshold)
        self.smoothing = float(smoothing_factor)
        self.split_y = float(split_y)
        self.col_left_x = float(col_left_x)
        self.col_right_x = float(col_right_x)
        self.invert_zones = bool(invert_zones)

        self.tracks: dict[int, TrackedPerson] = {}
        self.next_track_id = 1
        self.last_update_time: float | None = None

    @staticmethod
    def _compute_iou(box_a: Box, box_b: Box) -> float:
        """Return IoU for normalized ``(x1, y1, x2, y2)`` boxes."""
        xa1, ya1, xa2, ya2 = box_a
        xb1, yb1, xb2, yb2 = box_b
        area_a = max(0.0, xa2 - xa1) * max(0.0, ya2 - ya1)
        area_b = max(0.0, xb2 - xb1) * max(0.0, yb2 - yb1)
        if area_a <= 0 or area_b <= 0:
            return 0.0

        inter_x1 = max(xa1, xb1)
        inter_y1 = max(ya1, yb1)
        inter_x2 = min(xa2, xb2)
        inter_y2 = min(ya2, yb2)
        if inter_x2 <= inter_x1 or inter_y2 <= inter_y1:
            return 0.0
        inter_area = (inter_x2 - inter_x1) * (inter_y2 - inter_y1)
        union = area_a + area_b - inter_area
        return inter_area / union if union > 0 else 0.0

    @staticmethod
    def _centroid(box: Box) -> tuple[float, float]:
        return ((box[0] + box[2]) / 2.0, (box[1] + box[3]) / 2.0)

    @staticmethod
    def _upper_body_anchor(box: Box) -> tuple[float, float]:
        return ((box[0] + box[2]) / 2.0, box[1] + 0.25 * (box[3] - box[1]))

    @staticmethod
    def _box_diagonal(box: Box) -> float:
        return math.hypot(max(0.0, box[2] - box[0]), max(0.0, box[3] - box[1]))

    def _centroid_gate(self, track: TrackedPerson, detection: Box) -> float:
        # A fallback match must be close in absolute normalized distance and
        # relative to the size of both boxes. This prevents casually joining
        # adjacent students whose boxes happen to be in the same aisle.
        smallest_diagonal = min(self._box_diagonal(track.bbox), self._box_diagonal(detection))
        return min(self.dist_thresh, 0.45 * smallest_diagonal)

    def classify_zone(self, anchor: tuple[float, float]) -> tuple[str, str, bool]:
        ax, ay = anchor
        is_front_raw = ay < self.split_y
        is_front = (not is_front_raw) if self.invert_zones else is_front_raw
        is_left = ax < 0.5
        if is_front and is_left:
            quadrant = "front_left"
        elif is_front:
            quadrant = "front_right"
        elif is_left:
            quadrant = "back_left"
        else:
            quadrant = "back_right"
        if ax < self.col_left_x:
            column = "left"
        elif ax < self.col_right_x:
            column = "centre"
        else:
            column = "right"
        depth = "near" if is_front else "far"
        return quadrant, f"{column}_{depth}", is_front

    def update(
        self, detections: list[Detection], now: float | None = None
    ) -> list[TrackedPerson]:
        """Associate one frame of detections and return retained track objects."""
        now = time.monotonic() if now is None else float(now)
        if not math.isfinite(now):
            raise ValueError("now must be finite")
        if self.last_update_time is not None and now < self.last_update_time:
            raise ValueError("tracker clock moved backwards")
        dt = now - self.last_update_time if self.last_update_time is not None else 0.1
        dt = max(0.01, min(dt, 2.0))
        self.last_update_time = now

        for person in self.tracks.values():
            person.current_frame_observed = False

        unmatched_dets = set(range(len(detections)))
        unmatched_tracks = set(self.tracks)
        matched_pairs: list[tuple[int, int]] = []

        # Greedy maximum-IoU matching is one-to-one: matched rows and columns
        # are removed before another pair can be selected.
        track_ids = list(self.tracks)
        iou_matrix = [
            [self._compute_iou(self.tracks[tid].bbox, det_box) for det_box, _ in detections]
            for tid in track_ids
        ]
        while iou_matrix and iou_matrix[0] and unmatched_dets and unmatched_tracks:
            best: tuple[float, int, int] | None = None
            for row, tid in enumerate(track_ids):
                if tid not in unmatched_tracks:
                    continue
                for col in unmatched_dets:
                    value = iou_matrix[row][col]
                    if best is None or value > best[0]:
                        best = (value, row, col)
            if best is None or best[0] < self.iou_threshold:
                break
            _, row, col = best
            tid = track_ids[row]
            matched_pairs.append((tid, col))
            unmatched_tracks.remove(tid)
            unmatched_dets.remove(col)

        # A conservative, globally ordered fallback handles small box shifts
        # without allowing a detection to update two tracks.
        candidates: list[tuple[float, int, int]] = []
        for tid in unmatched_tracks:
            old_c = self.tracks[tid].centroid
            for det_idx in unmatched_dets:
                det_box, _ = detections[det_idx]
                dist = math.hypot(
                    self._centroid(det_box)[0] - old_c[0],
                    self._centroid(det_box)[1] - old_c[1],
                )
                if dist <= self._centroid_gate(self.tracks[tid], det_box):
                    candidates.append((dist, tid, det_idx))
        for _, tid, det_idx in sorted(candidates):
            if tid not in unmatched_tracks or det_idx not in unmatched_dets:
                continue
            matched_pairs.append((tid, det_idx))
            unmatched_tracks.remove(tid)
            unmatched_dets.remove(det_idx)

        for tid, det_idx in matched_pairs:
            det_box, conf = detections[det_idx]
            person = self.tracks[tid]
            new_c = self._centroid(det_box)
            old_c = person.centroid
            raw_vx = (new_c[0] - old_c[0]) / dt
            raw_vy = (new_c[1] - old_c[1]) / dt
            old_vx, old_vy = person.velocity
            vx = self.smoothing * old_vx + (1.0 - self.smoothing) * raw_vx
            vy = self.smoothing * old_vy + (1.0 - self.smoothing) * raw_vy
            speed = math.hypot(vx, vy)
            anchor = self._upper_body_anchor(det_box)
            quadrant, zone6, is_front = self.classify_zone(anchor)

            if speed <= self.motion_speed_threshold:
                old_box = person.bbox
                person.bbox = tuple(
                    0.4 * old + 0.6 * new
                    for old, new in zip(old_box, det_box, strict=True)
                )
            else:
                person.bbox = det_box
            person.centroid = new_c
            person.anchor = anchor
            person.confidence = conf
            person.velocity = (vx, vy)
            person.speed = speed
            person.state = "MOVING" if speed > self.motion_speed_threshold else "STATIONARY"
            person.zone = quadrant
            person.zone6 = zone6
            person.is_front = is_front
            person.last_seen_time = now
            person.frames_tracked += 1
            person.missed_frames = 0
            person.current_frame_observed = True
            person.confirmation_hits += 1
            if person.lifecycle == "TENTATIVE" and (
                person.confirmation_hits >= self.confirmation_hits_required
            ):
                person.lifecycle = "CONFIRMED"
            elif person.lifecycle == "RETAINED":
                person.lifecycle = "CONFIRMED"

        for tid in list(unmatched_tracks):
            person = self.tracks[tid]
            person.missed_frames += 1
            if person.lifecycle == "CONFIRMED":
                person.lifecycle = "RETAINED"
            if now - person.last_seen_time > self.max_age_seconds:
                person.lifecycle = "EXPIRED"
                del self.tracks[tid]

        for det_idx in sorted(unmatched_dets):
            det_box, conf = detections[det_idx]
            centroid = self._centroid(det_box)
            anchor = self._upper_body_anchor(det_box)
            quadrant, zone6, is_front = self.classify_zone(anchor)
            self.tracks[self.next_track_id] = TrackedPerson(
                track_id=self.next_track_id,
                bbox=det_box,
                centroid=centroid,
                anchor=anchor,
                zone6=zone6,
                confidence=conf,
                zone=quadrant,
                is_front=is_front,
                last_seen_time=now,
            )
            self.next_track_id += 1

        return list(self.tracks.values())

    def diagnostics(self) -> dict[str, int]:
        """Return lifecycle counts; current counts never include retained tracks."""
        return {
            "observed_confirmed_count": sum(
                p.lifecycle == "CONFIRMED" and p.current_frame_observed
                for p in self.tracks.values()
            ),
            "tentative_track_count": sum(
                p.lifecycle == "TENTATIVE" for p in self.tracks.values()
            ),
            "retained_track_count": sum(
                p.lifecycle == "RETAINED" for p in self.tracks.values()
            ),
        }

    def observed_confirmed(self) -> list[TrackedPerson]:
        return [
            person
            for person in self.tracks.values()
            if person.lifecycle == "CONFIRMED" and person.current_frame_observed
        ]
