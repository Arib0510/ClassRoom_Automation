import copy
import json
from dataclasses import replace

import numpy as np
import pytest

from src.config import REPO_ROOT, load_config
from src.detector import ModelContractError, SSDAdapter, verify_model


class FakeInterpreter:
    """Synthetic tensors only; never loads a model or inference runtime."""

    def __init__(self, config):
        self.config = config
        self.invocations = 0
        self.input = dict(
            index=7,
            shape=np.array([1, config.input_height, config.input_width, 3]),
            dtype=np.dtype(config.input_dtype),
            quantization=(config.input_scale, config.input_zero_point),
        )
        self.values = {
            42: np.array([[0.9, 0.95, 0.1]], dtype=np.float32),  # scores first
            17: np.array(
                [[[0.1, 0.2, 0.8, 0.4], [0, 0, 0.5, 0.5], [0, 0, 1, 1]]], dtype=np.float32
            ),
            93: np.array([3], dtype=np.float32),
            11: np.array([[0, 1, 0]], dtype=np.float32),
        }
        self.outputs = [
            dict(index=i, name="deliberately_uninformative", shape=v.shape, dtype=v.dtype)
            for i, v in self.values.items()
        ]

    def allocate_tensors(self):
        pass

    def get_input_details(self):
        return [self.input]

    def get_output_details(self):
        return self.outputs

    def get_tensor(self, index):
        return self.values[index]

    def set_tensor(self, index, value):
        assert index == 7
        self.submitted = value

    def invoke(self):
        self.invocations += 1


@pytest.fixture
def config():
    return replace(load_config().detector, input_width=2, input_height=2)


def test_person_filter_explicit_output_positions_and_normalized_coordinates(config):
    fake = FakeInterpreter(config)
    adapter = SSDAdapter(config, fake)
    result = adapter.detect(np.zeros((4, 8, 3), dtype=np.uint8))
    assert len(result) == 1
    assert result[0].class_id == 0
    assert result[0].box == pytest.approx((0.1, 0.2, 0.8, 0.4))
    assert fake.submitted.shape == (1, 2, 2, 3)
    assert fake.invocations == 1


def test_raw_rgb_keeps_channels_and_byte_values(config):
    adapter = SSDAdapter(config, FakeInterpreter(config))
    rgb = np.full((2, 2, 3), [255, 128, 0], dtype=np.uint8)
    np.testing.assert_array_equal(adapter.prepare(rgb)[0], rgb)


@pytest.mark.parametrize(
    "dtype,scale,zero,mean,std,expected",
    [
        ("int8", 1, 0, 128, 1, [-128, 0, 127]),
        ("uint8", 0.5, 100, 128, 1, [0, 100, 255]),
        ("float32", 0, 0, 127.5, 127.5, [-1, 1 / 255, 1]),
    ],
)
def test_configurable_normalization_and_quantization(
    config, dtype, scale, zero, mean, std, expected
):
    config = replace(
        config,
        input_encoding="normalized_real",
        input_dtype=dtype,
        input_scale=scale,
        input_zero_point=zero,
        input_mean=mean,
        input_std=std,
    )
    adapter = SSDAdapter(config, FakeInterpreter(config))
    rgb = np.full((2, 2, 3), [0, 128, 255], dtype=np.uint8)
    np.testing.assert_allclose(adapter.prepare(rgb)[0, 0, 0], expected, atol=1e-6)


@pytest.mark.parametrize(
    "fault", ["shape", "dtype", "quantization", "mapping", "output_shape", "per_axis"]
)
def test_incompatible_model_contract_fails_before_inference(config, fault):
    fake = FakeInterpreter(config)
    if fault == "shape":
        fake.input["shape"] = [1, 3, 2, 3]
    elif fault == "dtype":
        fake.input["dtype"] = np.float32
    elif fault == "quantization":
        fake.input["quantization"] = (1.0, 127)
    elif fault == "mapping":
        config = replace(config, classes_output=0)
    elif fault == "output_shape":
        fake.outputs[1]["shape"] = (1, 3, 5)
    else:
        fake.input["quantization_parameters"] = dict(scales=[1, 2], zero_points=[0, 0])
    with pytest.raises(ModelContractError):
        SSDAdapter(config, fake)
    assert fake.invocations == 0


@pytest.mark.parametrize(
    "fault", ["nan_score", "nan_box", "bad_count", "fractional_count", "bad_class", "box", "score"]
)
def test_invalid_outputs_never_become_empty_observations(config, fault):
    fake = FakeInterpreter(config)
    if fault == "nan_score":
        fake.values[42][0, 0] = np.nan
    elif fault == "nan_box":
        fake.values[17][0, 0, 0] = np.nan
    elif fault == "bad_count":
        fake.values[93][0] = 10
    elif fault == "fractional_count":
        fake.values[93][0] = 1.5
    elif fault == "bad_class":
        fake.values[11][0, 0] = 0.5
    elif fault == "box":
        fake.values[17][0, 0] = [0.9, 0.2, 0.1, 0.4]
    else:
        fake.values[42][0, 0] = 1.2
    adapter = SSDAdapter(config, fake)
    with pytest.raises(ModelContractError):
        adapter.detect(np.zeros((2, 2, 3), dtype=np.uint8))


def test_count_limits_valid_detections_and_clips_boxes(config):
    fake = FakeInterpreter(config)
    fake.values[93][0] = 1
    fake.values[17][0, 0] = [-0.1, 0.2, 1.1, 0.4]
    fake.values[42][0, 2] = np.nan  # unused slots must not be interpreted
    result = SSDAdapter(config, fake).detect(np.zeros((2, 2, 3), dtype=np.uint8))
    assert result[0].box == pytest.approx((0, 0.2, 1, 0.4))


def test_quantized_outputs_are_dequantized(config):
    fake = FakeInterpreter(config)
    fake.values[42] = np.array([[90, 95, 10]], dtype=np.uint8)
    fake.outputs[0].update(dtype=np.uint8, quantization=(0.01, 0))
    detections = SSDAdapter(config, fake).detect(np.zeros((2, 2, 3), dtype=np.uint8))
    assert detections[0].score == pytest.approx(0.9)


def test_model_and_label_integrity_checked_without_runtime(tmp_path):
    config = load_config().detector
    verify_model(config)
    path = tmp_path / "wrong.tflite"
    path.write_bytes(b"not a model")
    with pytest.raises(ModelContractError, match="SHA256"):
        verify_model(replace(config, model_path=path))
    with pytest.raises(ModelContractError, match="Missing model"):
        verify_model(replace(config, model_path=tmp_path / "missing"))
    labels = tmp_path / "wrong-labels.txt"
    labels.write_text("background\nperson\n")
    with pytest.raises(ModelContractError, match="person_class_id"):
        verify_model(replace(config, labels_path=labels))


def test_static_record_explains_nonstandard_output_mapping():
    record = json.loads((REPO_ROOT / "models/inspection.json").read_text())
    config = load_config().detector
    postprocess = next(
        op for op in record["custom_ops"] if op["name"] == "TFLite_Detection_PostProcess"
    )
    expected = [postprocess["outputs"][i] for i in range(4)]
    actual = [
        record["outputs"][p]["tensor_index"]
        for p in [
            config.boxes_output,
            config.classes_output,
            config.scores_output,
            config.count_output,
        ]
    ]
    assert actual == expected
    assert record["tensor_dtype_counts"]["INT8"] > 0
    assert record["inputs"][0]["dtype"] == "UINT8"
    assert all(op["name"] != "edgetpu-custom-op" for op in record["custom_ops"])


def test_bad_frame_rejected(config):
    adapter = SSDAdapter(config, FakeInterpreter(config))
    for frame in [np.zeros((2, 2, 3), dtype=np.float32), np.zeros((2, 2), dtype=np.uint8)]:
        with pytest.raises(ValueError):
            adapter.prepare(frame)


def test_output_shape_change_rejected(config):
    fake = FakeInterpreter(config)
    adapter = SSDAdapter(config, fake)
    fake.values = copy.deepcopy(fake.values)
    fake.values[42] = np.zeros((1, 2), dtype=np.float32)
    with pytest.raises(ModelContractError):
        adapter.detect(np.zeros((2, 2, 3), dtype=np.uint8))
