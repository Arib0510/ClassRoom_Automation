"""Lazy, explicit CPU interpreter selection; no fallback to a different backend/model."""

from __future__ import annotations

import importlib.metadata
import sys
from pathlib import Path
from typing import Any

import numpy as np


def create_interpreter(model_path: Path, num_threads: int, backend: str) -> tuple[Any, dict]:
    if backend == "auto":
        backend = "tensorflow" if sys.platform == "win32" else "tflite-runtime"
    if backend == "tensorflow":
        try:
            import tensorflow as tf
        except (ImportError, OSError) as exc:
            raise RuntimeError(
                "TensorFlow CPU could not load. Use scripts/setup_windows_inference.ps1 "
                "and .venv-inference; native Windows requires the x64 VC++ redistributable. "
                f"Original error: {type(exc).__name__}: {exc}"
            ) from exc
        interpreter_type = tf.lite.Interpreter
        resolver = tf.lite.experimental.OpResolverType.BUILTIN_WITHOUT_DEFAULT_DELEGATES
        version = tf.__version__
        distributions = {}
        for name in ("tensorflow-cpu", "tensorflow-intel", "tensorflow"):
            try:
                distributions[name] = importlib.metadata.version(name)
            except importlib.metadata.PackageNotFoundError:
                pass
    elif backend == "tflite-runtime":
        try:
            from tflite_runtime.interpreter import Interpreter, OpResolverType
        except (ImportError, OSError) as exc:
            raise RuntimeError(
                "tflite-runtime could not load; on the Pi use scripts/setup_pi.sh. "
                f"Original error: {type(exc).__name__}: {exc}"
            ) from exc
        interpreter_type = Interpreter
        resolver = OpResolverType.BUILTIN_WITHOUT_DEFAULT_DELEGATES
        version = importlib.metadata.version("tflite-runtime")
        distributions = {"tflite-runtime": version}
    else:
        raise ValueError(f"Unsupported inference backend: {backend}")
    interpreter = interpreter_type(
        model_path=str(model_path),
        num_threads=num_threads,
        experimental_op_resolver_type=resolver,
    )
    return interpreter, {
        "backend": backend,
        "version": version,
        "distributions": distributions,
        "interpreter_class": f"{interpreter_type.__module__}.{interpreter_type.__name__}",
        "execution": "CPU",
        "default_delegates": False,
        "num_threads": num_threads,
    }


def tensor_metadata(detail: dict) -> dict:
    """Serialize actual allocated interpreter details, including quantization arrays."""
    params = detail.get("quantization_parameters", {})
    scale, zero = detail.get("quantization", (0.0, 0))
    return {
        "name": detail.get("name", ""),
        "index": int(detail["index"]),
        "shape": [int(v) for v in detail["shape"]],
        "shape_signature": [int(v) for v in detail.get("shape_signature", [])],
        "dtype": np.dtype(detail["dtype"]).name,
        "quantization": {"scale": float(scale), "zero_point": int(zero)},
        "quantization_parameters": {
            "scales": np.asarray(params.get("scales", [])).tolist(),
            "zero_points": np.asarray(params.get("zero_points", [])).tolist(),
            "quantized_dimension": int(params.get("quantized_dimension", 0)),
        },
    }
