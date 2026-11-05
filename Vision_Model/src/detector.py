"""Explicit SSD Detection_PostProcess adapter. No tensor-order heuristics."""

from __future__ import annotations

import hashlib
import math
from dataclasses import dataclass
from typing import Any

import numpy as np
from PIL import Image

from .config import DetectorConfig


class ModelContractError(ValueError):
    """The supplied model does not match its reviewed configuration."""


@dataclass(frozen=True)
class Detection:
    box: tuple[float, float, float, float]  # ymin, xmin, ymax, xmax in original image
    score: float
    class_id: int


def verify_model(config: DetectorConfig) -> None:
    if not config.model_path.is_file():
        raise ModelContractError(f"Missing model: {config.model_path}; see models/README.md")
    with config.model_path.open("rb") as handle:
        digest = hashlib.file_digest(handle, "sha256").hexdigest()
    if digest.lower() != config.sha256.lower():
        raise ModelContractError("Model SHA256 mismatch: review provenance before changing config")
    labels = config.labels_path.read_text(encoding="utf-8").splitlines()
    if config.person_class_id >= len(labels) or labels[config.person_class_id].strip() != "person":
        raise ModelContractError("person_class_id does not reference 'person' in the label file")


def _quantization(detail: dict) -> tuple[float, int]:
    params = detail.get("quantization_parameters", {})
    scales = np.asarray(params.get("scales", []))
    zeros = np.asarray(params.get("zero_points", []))
    if scales.size > 1 or zeros.size > 1:
        raise ModelContractError("Per-axis quantized I/O is unsupported")
    scale, zero = detail.get("quantization", (0.0, 0))
    if scales.size == 1 and zeros.size == 1:
        scale, zero = float(scales[0]), int(zeros[0])
    if not math.isfinite(scale) or scale <= 0:
        raise ModelContractError("Integer I/O requires a positive per-tensor quantization scale")
    return float(scale), int(zero)


class SSDAdapter:
    """One SSD contract shared by real CPU interpreters and injected unit-test fixtures."""

    def __init__(self, config: DetectorConfig, interpreter: Any):
        self.config = config
        self.interpreter = interpreter
        self.runtime_info: dict = {}
        self.invocation_count = 0
        interpreter.allocate_tensors()
        inputs = interpreter.get_input_details()
        self.outputs = interpreter.get_output_details()
        if len(inputs) != 1 or len(self.outputs) != 4:
            raise ModelContractError(
                "SSD contract requires one image input and four postprocessed outputs"
            )
        self.input = inputs[0]
        self.input_height = int(self.input["shape"][1]) if len(self.input["shape"]) == 4 else 0
        self.input_width = int(self.input["shape"][2]) if len(self.input["shape"]) == 4 else 0
        wanted = (1, config.input_height, config.input_width, 3)
        if tuple(self.input["shape"]) != wanted:
            raise ModelContractError(f"Expected NHWC input {wanted}, got {self.input['shape']}")
        self.dtype = np.dtype(self.input["dtype"])
        if self.dtype != np.dtype(config.input_dtype):
            raise ModelContractError(
                f"Input dtype {self.dtype} differs from config {config.input_dtype}"
            )
        if config.input_encoding == "raw_uint8" and self.dtype != np.dtype("uint8"):
            raise ModelContractError("raw_uint8 encoding requires uint8 model input")
        self.input_quant = None
        if np.issubdtype(self.dtype, np.integer):
            self.input_quant = _quantization(self.input)
            scale, zero = self.input_quant
            if (
                not math.isclose(scale, config.input_scale, rel_tol=1e-6, abs_tol=1e-10)
                or zero != config.input_zero_point
            ):
                raise ModelContractError("Input quantization differs from reviewed configuration")
        positions = [
            config.boxes_output,
            config.classes_output,
            config.scores_output,
            config.count_output,
        ]
        if sorted(positions) != [0, 1, 2, 3]:
            raise ModelContractError("Four distinct output positions (0-3) are required")
        boxes, classes, scores, count = [self.outputs[p] for p in positions]
        shape = tuple(boxes["shape"])
        if len(shape) != 3 or shape[0] != 1 or shape[2] != 4 or shape[1] < 1:
            raise ModelContractError("Boxes output must have shape [1,N,4] after allocation")
        self.capacity = int(shape[1])
        if tuple(classes["shape"]) != (1, self.capacity) or tuple(scores["shape"]) != (
            1,
            self.capacity,
        ):
            raise ModelContractError("Class and score outputs must have shape [1,N]")
        if tuple(count["shape"]) not in ((1,), (1, 1)):
            raise ModelContractError("Count output must have one element")
        for detail in self.outputs:
            dtype = np.dtype(detail["dtype"])
            if dtype not in (
                np.dtype("float32"),
                np.dtype("uint8"),
                np.dtype("int8"),
                np.dtype("int32"),
            ):
                raise ModelContractError(f"Unsupported output dtype: {dtype}")
            if np.issubdtype(dtype, np.integer):
                _quantization(detail)

    def prepare(self, rgb: np.ndarray) -> np.ndarray:
        if rgb.dtype != np.uint8 or rgb.ndim != 3 or rgb.shape[2] != 3 or min(rgb.shape[:2]) < 1:
            raise ValueError("Camera frame must be a nonempty HWC uint8 RGB image")
        # Stretch resize preserves normalized coordinates: no letterbox offsets to undo.
        resized = Image.fromarray(rgb).resize(
            (self.input_width, self.input_height), Image.Resampling.BILINEAR
        )
        if self.config.input_encoding == "raw_uint8":
            return np.asarray(resized, dtype=np.uint8)[np.newaxis, ...]
        real = (
            np.asarray(resized, dtype=np.float32) - self.config.input_mean
        ) / self.config.input_std
        if self.input_quant is not None:
            scale, zero = self.input_quant
            limits = np.iinfo(self.dtype)
            real = np.clip(np.rint(real / scale + zero), limits.min, limits.max)
        return real.astype(self.dtype)[np.newaxis, ...]

    def _output(self, position: int) -> np.ndarray:
        detail = self.outputs[position]
        value = np.asarray(self.interpreter.get_tensor(detail["index"]))
        if tuple(value.shape) != tuple(detail["shape"]) or value.dtype != np.dtype(detail["dtype"]):
            raise ModelContractError("Runtime output shape or dtype changed")
        if np.issubdtype(value.dtype, np.integer):
            scale, zero = _quantization(detail)
            return (value.astype(np.float32) - zero) * scale
        return value

    def detect(
        self, rgb: np.ndarray, *, confidence_threshold: float | None = None
    ) -> list[Detection]:
        # A per-call override supports offline diagnostics without changing production config.
        threshold = (
            self.config.confidence_threshold
            if confidence_threshold is None
            else confidence_threshold
        )
        if isinstance(threshold, bool) or not math.isfinite(threshold) or not 0 <= threshold <= 1:
            raise ValueError("confidence_threshold must be finite and in [0,1]")
        self.interpreter.set_tensor(self.input["index"], self.prepare(rgb))
        self.interpreter.invoke()
        self.invocation_count += 1
        c = self.config
        boxes = self._output(c.boxes_output)[0]
        classes = self._output(c.classes_output)[0]
        scores = self._output(c.scores_output)[0]
        raw_count = float(self._output(c.count_output).reshape(-1)[0])
        if (
            not math.isfinite(raw_count)
            or abs(raw_count - round(raw_count)) > 1e-3
            or not 0 <= raw_count <= self.capacity
        ):
            raise ModelContractError("Invalid detection count; refusing to infer vacancy")
        detections = []
        for i in range(round(raw_count)):
            score, class_id = float(scores[i]), float(classes[i])
            box = np.asarray(boxes[i], dtype=np.float64)
            if (
                not np.all(np.isfinite(box))
                or not math.isfinite(score)
                or not math.isfinite(class_id)
            ):
                raise ModelContractError("Nonfinite SSD detection; refusing to infer vacancy")
            if not 0 <= score <= 1 or class_id < 0 or abs(class_id - round(class_id)) > 1e-3:
                raise ModelContractError("Invalid SSD score or class ID")
            if round(class_id) != c.person_class_id or score < threshold:
                continue
            ymin, xmin, ymax, xmax = map(float, np.clip(box, 0, 1))
            if ymin >= ymax or xmin >= xmax:
                raise ModelContractError("Degenerate person box; refusing to infer vacancy")
            detections.append(Detection((ymin, xmin, ymax, xmax), score, round(class_id)))
        return detections

    def allocated_metadata(self) -> dict:
        from .inference_runtime import tensor_metadata

        roles = {
            "boxes": self.config.boxes_output,
            "classes": self.config.classes_output,
            "scores": self.config.scores_output,
            "count": self.config.count_output,
        }
        # This diagnostic API is available in the selected TensorFlow runtime.
        # Output selection still uses only the reviewed config positions.
        get_ops = getattr(self.interpreter, "_get_ops_details", None)
        operators = sorted({op["op_name"] for op in get_ops()}) if get_ops else []
        return {
            "allocated": True,
            "inputs": [tensor_metadata(self.input)],
            "outputs": [
                tensor_metadata(detail) | {"position": i} for i, detail in enumerate(self.outputs)
            ],
            "output_roles": roles,
            "capacity": self.capacity,
            "operator_names": operators,
            "ssd_postprocess_supported": "TFLite_Detection_PostProcess" in operators,
            "invocation_count": self.invocation_count,
        }


def create_detector(config: DetectorConfig, backend: str = "tflite-runtime") -> SSDAdapter:
    from .inference_runtime import create_interpreter

    verify_model(config)
    interpreter, runtime_info = create_interpreter(config.model_path, config.num_threads, backend)
    adapter = SSDAdapter(config, interpreter)
    adapter.runtime_info = runtime_info
    return adapter
