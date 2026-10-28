import copy

import pytest
import yaml

from src.config import REPO_ROOT, read_yaml
from src.zones import ZONE_IDS, ZoneMap


@pytest.fixture
def zones():
    return ZoneMap.load(REPO_ROOT / "config/zones.yaml")


@pytest.mark.parametrize(
    "box,expected",
    [
        ((0.6, 0.2, 0.8, 0.3), "front_left"),
        ((0.6, 0.7, 0.8, 0.8), "front_right"),
        ((0.2, 0.3, 0.3, 0.4), "back_left"),
        ((0.2, 0.6, 0.3, 0.7), "back_right"),
        ((0.0, 0.0, 0.1, 0.05), None),
        ((0.6, 0.4, 0.8, 0.6), "front_left"),  # shared edge priority
        ((0.2, 0.4, 0.48, 0.6), "front_left"),  # shared central vertex
        ((0.2, 0.3, 0.2, 0.4), None),
        ((0.2, 0.3, float("nan"), 0.4), None),
        ((0.2, 0.3, 1.1, 0.4), None),
    ],
)
def test_physical_polygon_assignment(zones, box, expected):
    assert zones.assign(box) == expected


def test_counts_are_independent_and_boundary_person_counted_once(zones):
    counts = zones.count([(0.6, 0.4, 0.8, 0.6), (0.2, 0.6, 0.3, 0.7)])
    assert counts == dict(front_left=1, front_right=0, back_left=0, back_right=1)
    assert sum(counts.values()) == 2
    assert not zones.calibrated


@pytest.mark.parametrize(
    "problem",
    ["missing", "duplicate", "overlap", "nan", "concave", "bowtie", "boolean", "unknown_key"],
)
def test_invalid_geometry_is_rejected(tmp_path, problem):
    data = copy.deepcopy(read_yaml(REPO_ROOT / "config/zones.yaml"))
    if problem == "missing":
        data["zones"].pop()
    elif problem == "duplicate":
        data["zones"][0]["id"] = data["zones"][1]["id"]
    elif problem == "overlap":
        data["zones"][1]["polygon"] = data["zones"][0]["polygon"]
    elif problem == "nan":
        data["zones"][0]["polygon"][0][0] = float("nan")
    elif problem == "concave":
        data["zones"][0]["polygon"] = [[0, 0], [0.5, 0], [0.1, 0.1], [0, 0.5]]
    elif problem == "bowtie":
        p = data["zones"][0]["polygon"]
        p[1], p[2] = p[2], p[1]
    elif problem == "boolean":
        data["calibrated"] = "false"
    else:
        data["mispelled"] = True
    path = tmp_path / "zones.yaml"
    path.write_text(yaml.safe_dump(data))
    with pytest.raises(ValueError):
        ZoneMap.load(path)


def test_center_anchor_and_winding(tmp_path):
    data = read_yaml(REPO_ROOT / "config/zones.yaml")
    data["anchor"] = "center"
    for zone in data["zones"]:
        zone["polygon"].reverse()
    path = tmp_path / "zones.yaml"
    path.write_text(yaml.safe_dump(data))
    zones = ZoneMap.load(path)
    assert zones.assign((0.2, 0.3, 0.6, 0.4)) == "back_left"
    assert tuple(z.id for z in zones.zones) == ZONE_IDS
