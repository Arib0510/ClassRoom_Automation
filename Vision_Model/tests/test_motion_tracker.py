"""Tests for FastMotionFilter and ObjectMotionTracker."""

import numpy as np
import pytest

from src.motion_tracker import FastMotionFilter, ObjectMotionTracker


def test_fast_motion_filter_static_vs_motion():
    filt = FastMotionFilter(threshold=20, min_motion_pixels=50)

    # First frame initializes
    frame1 = np.ones((480, 640, 3), dtype=np.uint8) * 128
    has_motion, ratio, _ = filt.check_motion(frame1)
    assert has_motion is True  # Cold start triggers

    # Identical second frame should report NO motion
    frame2 = np.ones((480, 640, 3), dtype=np.uint8) * 128
    has_motion, ratio, _ = filt.check_motion(frame2)
    assert has_motion is False
    assert ratio == 0.0

    # Frame with large motion block
    frame3 = frame2.copy()
    frame3[100:300, 100:300, :] = 255
    has_motion, ratio, _ = filt.check_motion(frame3)
    assert has_motion is True
    assert ratio > 0.05


def test_object_motion_tracker_stationary_student():
    tracker = ObjectMotionTracker(motion_speed_threshold=0.05)

    # Frame 1: Person sitting at (0.2, 0.2, 0.35, 0.4)
    t1 = 0.0
    dets1 = [(0.2, 0.2, 0.35, 0.4)]
    tracks1 = tracker.update(dets1, now=t1)
    assert len(tracks1) == 1
    assert tracks1[0].track_id == 1
    assert tracks1[0].state == "STATIONARY"
    assert tracks1[0].zone == "front_left"

    # Frame 2: 0.5s later, virtually unchanged position (stationary student)
    t2 = 0.5
    dets2 = [(0.201, 0.201, 0.351, 0.401)]
    tracks2 = tracker.update(dets2, now=t2)
    assert len(tracks2) == 1
    assert tracks2[0].track_id == 1
    assert tracks2[0].state == "STATIONARY"
    assert tracks2[0].speed < 0.02


def test_object_motion_tracker_moving_person():
    tracker = ObjectMotionTracker(motion_speed_threshold=0.05)

    # Frame 1: Person enters at (0.1, 0.1, 0.2, 0.3)
    t1 = 0.0
    tracker.update([(0.1, 0.1, 0.2, 0.3)], now=t1)

    # Frame 2: 0.5s later, person moved rapidly across aisle to (0.35, 0.1, 0.45, 0.3)
    t2 = 0.5
    tracks = tracker.update([(0.35, 0.1, 0.45, 0.3)], now=t2)
    assert len(tracks) >= 1
    # Check that high displacement results in MOVING classification or tracks
    # Even if IoU didn't match due to fast jump, new track is created
    # Now let's test a continuous walking sequence with overlapping IoU
    tracker2 = ObjectMotionTracker(iou_threshold=0.1, motion_speed_threshold=0.05)
    tracker2.update([(0.1, 0.1, 0.3, 0.4)], now=0.0)
    tracks2 = tracker2.update([(0.18, 0.18, 0.38, 0.48)], now=0.2)
    assert len(tracks2) == 1
    assert tracks2[0].track_id == 1
    assert tracks2[0].state == "MOVING"
    assert tracks2[0].speed > 0.05


def test_track_expiry_after_missed_frames():
    tracker = ObjectMotionTracker(max_missed_frames=2)
    tracker.update([(0.1, 0.1, 0.2, 0.2)], now=0.0)
    assert len(tracker.tracks) == 1

    # Miss frame 1
    tracker.update([], now=0.1)
    assert len(tracker.tracks) == 1
    assert tracker.tracks[1].missed_frames == 1

    # Miss frame 2
    tracker.update([], now=0.2)
    assert len(tracker.tracks) == 1
    assert tracker.tracks[1].missed_frames == 2

    # Miss frame 3 -> should expire and delete
    tracker.update([], now=0.3)
    assert len(tracker.tracks) == 0

