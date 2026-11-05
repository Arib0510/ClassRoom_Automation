import pytest

from src.config import OccupancyConfig
from src.occupancy import OccupancyTracker
from src.zones import ZONE_IDS


def counts(**occupied):
    return {key: occupied.get(key, 0) for key in ZONE_IDS}


def test_startup_and_first_empty_observation_remain_unknown():
    tracker = OccupancyTracker(OccupancyConfig())
    assert all(
        v["state"] == "unknown" and v["person_count"] is None for v in tracker.snapshot(0).values()
    )
    tracker.update(counts(), 0)
    assert tracker.snapshot(0)["front_left"]["state"] == "unknown"


def test_arrival_requires_hits_and_time_independently_per_quadrant():
    tracker = OccupancyTracker(OccupancyConfig())
    tracker.update(counts(front_left=1), 0)
    tracker.update(counts(front_left=1), 0.1)
    assert tracker.snapshot(0.1)["front_left"]["state"] == "unknown"
    tracker.update(counts(front_left=2, back_right=1), 0.6)
    assert tracker.snapshot(0.6)["front_left"]["state"] == "occupied"
    assert tracker.snapshot(0.6)["back_right"]["state"] == "unknown"
    tracker.update(counts(front_left=2, back_right=1), 1.2)
    snap = tracker.snapshot(1.2)
    assert snap["back_right"]["state"] == "occupied"
    assert snap["front_right"]["state"] == "unknown"


def test_no_single_frame_flicker_and_empty_delay_starts_at_first_miss():
    tracker = OccupancyTracker(OccupancyConfig(clear_seconds=2))
    for t in (0, 0.6):
        tracker.update(counts(front_left=1), t)
    tracker.update(counts(), 1)
    assert tracker.snapshot(1)["front_left"]["state"] == "occupied"
    tracker.update(counts(front_left=1), 1.5)
    for t in (2, 3, 3.9):
        tracker.update(counts(), t)
    assert tracker.snapshot(3.9)["front_left"]["state"] == "occupied"
    tracker.update(counts(), 4)
    assert tracker.snapshot(4)["front_left"]["state"] == "vacant"


def test_startup_vacancy_requires_sustained_valid_empty_frames():
    tracker = OccupancyTracker(OccupancyConfig(clear_seconds=2))
    for t in (0, 1, 2):
        tracker.update(counts(), t)
    assert all(v["state"] == "vacant" for v in tracker.snapshot(2).values())


def test_stale_data_becomes_unknown_and_recovery_redebounces():
    tracker = OccupancyTracker(OccupancyConfig())
    tracker.update(counts(front_left=1), 0)
    tracker.update(counts(front_left=1), 0.6)
    assert tracker.snapshot(0.6)["front_left"]["state"] == "occupied"
    assert all(
        v["state"] == "unknown" and v["person_count"] is None for v in tracker.snapshot(5).values()
    )
    tracker.update(counts(front_left=1), 5.1)
    assert tracker.snapshot(5.1)["front_left"]["state"] == "unknown"
    tracker.update(counts(front_left=1), 5.7)
    assert tracker.snapshot(5.7)["front_left"]["state"] == "occupied"


def test_long_gap_cannot_confirm_an_empty_room():
    tracker = OccupancyTracker(OccupancyConfig())
    tracker.update(counts(), 0)
    tracker.update(counts(), 20)
    assert tracker.snapshot(20)["front_left"]["state"] == "unknown"


@pytest.mark.parametrize("bad", [-1, True, 1.5, None])
def test_invalid_counts_rejected(bad):
    with pytest.raises(ValueError):
        OccupancyTracker(OccupancyConfig()).update(counts(front_left=bad), 0)


def test_clock_and_missing_zone_errors():
    tracker = OccupancyTracker(OccupancyConfig())
    tracker.update(counts(), 1)
    with pytest.raises(ValueError):
        tracker.update(counts(), 0)
    with pytest.raises(ValueError):
        tracker.snapshot(float("nan"))
    with pytest.raises(ValueError):
        tracker.update({}, 2)
