import pytest

from src.classroom_tracker import ClassroomMotionTracker

BOX = (0.10, 0.10, 0.25, 0.40)


def detection(box=BOX, confidence=0.9):
    return (box, confidence)


def confirmed_tracker(**kwargs):
    tracker = ClassroomMotionTracker(**kwargs)
    tracker.update([detection()], now=0.0)
    tracker.update([detection()], now=0.1)
    return tracker


def test_iou_is_symmetric_and_handles_degenerate_boxes():
    iou = ClassroomMotionTracker._compute_iou
    a = (0.0, 0.0, 0.5, 0.8)
    b = (0.1, 0.2, 0.4, 0.4)
    assert iou(a, a) == pytest.approx(1.0)
    assert iou(a, b) == pytest.approx(0.15)  # Unequal heights catch area_b bugs.
    assert iou(a, b) == pytest.approx(iou(b, a))
    assert iou(a, (0.6, 0.0, 0.8, 0.2)) == 0.0
    assert iou((0.2, 0.2, 0.2, 0.4), (0.2, 0.2, 0.2, 0.4)) == 0.0


def test_six_zone_mapping_uses_upper_body_anchor_and_front_inversion():
    tracker = ClassroomMotionTracker(split_y=0.48, invert_zones=True)
    assert tracker.classify_zone((0.2, 0.2)) == ("back_left", "left_far", False)
    assert tracker.classify_zone((0.5, 0.7)) == ("front_right", "centre_near", True)


def test_stationary_person_confirms_once_and_keeps_one_id():
    tracker = ClassroomMotionTracker()
    first = tracker.update([detection()], now=0.0)
    assert first[0].lifecycle == "TENTATIVE"
    assert tracker.diagnostics()["observed_confirmed_count"] == 0

    second = tracker.update([detection()], now=0.1)
    assert second[0].lifecycle == "CONFIRMED"
    assert tracker.diagnostics()["observed_confirmed_count"] == 1

    third = tracker.update([detection()], now=0.2)
    assert [person.track_id for person in third] == [1]
    assert tracker.diagnostics()["observed_confirmed_count"] == 1


def test_brief_gap_retains_then_reappearance_reuses_track():
    tracker = confirmed_tracker(max_age_seconds=1.0)
    gap = tracker.update([], now=0.5)
    assert gap[0].lifecycle == "RETAINED"
    assert tracker.diagnostics()["observed_confirmed_count"] == 0
    assert tracker.diagnostics()["retained_track_count"] == 1

    returned = tracker.update([detection()], now=0.8)
    assert returned[0].track_id == 1
    assert returned[0].lifecycle == "CONFIRMED"
    assert tracker.diagnostics()["observed_confirmed_count"] == 1


def test_tentative_and_retained_tracks_do_not_inflate_current_count():
    tracker = confirmed_tracker(max_age_seconds=1.0)
    tracker.update(
        [detection(), detection((0.6, 0.1, 0.75, 0.4))], now=0.2
    )
    counts = tracker.diagnostics()
    assert counts["observed_confirmed_count"] == 1
    assert counts["tentative_track_count"] == 1

    tracker.update([], now=0.3)
    counts = tracker.diagnostics()
    assert counts["observed_confirmed_count"] == 0
    assert counts["retained_track_count"] == 1
    assert counts["tentative_track_count"] == 1


def test_adjacent_people_remain_separate():
    tracker = ClassroomMotionTracker(centroid_distance_thresh=0.06)
    boxes = [BOX, (0.32, 0.10, 0.47, 0.40)]
    tracker.update([detection(box) for box in boxes], now=0.0)
    tracks = tracker.update([detection(box) for box in boxes], now=0.1)
    assert [person.track_id for person in tracks] == [1, 2]
    assert tracker.diagnostics()["observed_confirmed_count"] == 2


def test_matching_is_one_to_one_in_both_directions():
    tracker = confirmed_tracker()
    one = tracker.update([detection()], now=0.2)
    assert len(one) == 1
    assert tracker.diagnostics()["observed_confirmed_count"] == 1

    tracker = confirmed_tracker()
    two = tracker.update([detection(), detection((0.7, 0.1, 0.85, 0.4))], now=0.2)
    assert len(two) == 2
    assert {person.track_id for person in two} == {1, 2}
    assert tracker.diagnostics()["observed_confirmed_count"] == 1
    assert tracker.diagnostics()["tentative_track_count"] == 1


def test_shifted_box_uses_conservative_fallback_without_duplicate():
    tracker = ClassroomMotionTracker(iou_threshold=0.5, centroid_distance_thresh=0.06)
    tracker.update([detection((0.10, 0.10, 0.25, 0.40))], now=0.0)
    shifted = (0.15, 0.10, 0.30, 0.40)
    tracks = tracker.update([detection(shifted)], now=0.1)
    assert len(tracks) == 1
    assert tracks[0].track_id == 1


def test_expiry_is_elapsed_time_based_at_different_frame_rates():
    fast = confirmed_tracker(max_age_seconds=1.0)
    for now in (0.25, 0.50, 0.75, 0.99):
        fast.update([], now=now)
    assert len(fast.tracks) == 1
    fast.update([], now=1.11)
    assert not fast.tracks

    slow = confirmed_tracker(max_age_seconds=1.0)
    slow.update([], now=0.90)
    assert len(slow.tracks) == 1
    slow.update([], now=1.11)
    assert not slow.tracks
