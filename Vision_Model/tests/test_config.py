import copy
import sys

import pytest
import yaml

from src.config import REPO_ROOT, load_config, read_yaml
from src.main import main


@pytest.mark.parametrize(
    "section,key,value",
    [
        ("camera", "width", True),
        ("camera", "hflip", "false"),
        ("detector", "confidence_threshold", float("nan")),
        ("detector", "num_threads", 0),
        ("detector", "sha256", "guess"),
        ("detector", "classes_output", 0),
        ("detector", "person_class_id", -1),
        ("detector", "input_std", 0),
        ("detector", "input_encoding", "auto"),
        ("mqtt", "port", 0),
        ("mqtt", "topic_prefix", "room/#"),
        ("mqtt", "expiry_seconds", 1),
        ("occupancy", "enter_hits", 1.5),
        ("camera", "typo", 1),
    ],
)
def test_invalid_config_fails_early(tmp_path, section, key, value):
    data = copy.deepcopy(read_yaml(REPO_ROOT / "config/config.yaml"))
    data[section][key] = value
    path = tmp_path / "config.yaml"
    path.write_text(yaml.safe_dump(data))
    with pytest.raises(ValueError):
        load_config(path)


def test_paths_resolve_against_config_directory(monkeypatch, tmp_path):
    monkeypatch.chdir(tmp_path)
    config = load_config()
    assert config.detector.model_path == REPO_ROOT / "models/ssd_mobilenet_v2_coco_quant.tflite"


def test_check_and_simulation_never_import_hardware_or_interpreter(capsys):
    assert main(["check-config"]) == 0
    assert "PENDING" in capsys.readouterr().out
    assert main(["simulate"]) == 0
    lines = capsys.readouterr().out.splitlines()
    assert len(lines) == 61
    assert "picamera2" not in sys.modules
    assert "tflite_runtime.interpreter" not in sys.modules


def test_live_run_refuses_uncalibrated_zone_file():
    assert main(["run"]) == 1


def test_invalid_yaml_is_reported_as_config_error(tmp_path):
    path = tmp_path / "invalid.yaml"
    path.write_text("camera: [unclosed\n")
    with pytest.raises(ValueError, match="invalid YAML"):
        load_config(path)
