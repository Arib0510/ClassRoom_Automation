"""Inspect FlatBuffer structure only. Never allocate an interpreter or run inference."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))


def inspect_model(path: Path) -> dict:
    import tflite
    from flatbuffers import flexbuffers

    data = path.read_bytes()
    if data[4:8] != b"TFL3":
        raise ValueError("File has no TFL3 FlatBuffer identifier")
    model = tflite.Model.GetRootAsModel(data, 0)
    if model.SubgraphsLength() != 1:
        raise ValueError("Expected one model subgraph")
    graph = model.Subgraphs(0)
    types = {v: k for k, v in vars(tflite.TensorType).items() if isinstance(v, int)}

    def tensor(index: int) -> dict:
        value = graph.Tensors(index)
        quant = value.Quantization()
        return {
            "tensor_index": int(index),
            "name": value.Name().decode(),
            "shape": [int(value.Shape(i)) for i in range(value.ShapeLength())],
            "dtype": types[value.Type()],
            "scales": []
            if quant is None
            else [float(quant.Scale(i)) for i in range(quant.ScaleLength())],
            "zero_points": []
            if quant is None
            else [int(quant.ZeroPoint(i)) for i in range(quant.ZeroPointLength())],
        }

    custom_ops = []
    for i in range(graph.OperatorsLength()):
        op = graph.Operators(i)
        code = model.OperatorCodes(op.OpcodeIndex())
        if code.CustomCode():
            name = code.CustomCode().decode()
            custom_ops.append(
                {
                    "name": name,
                    "inputs": [int(v) for v in op.InputsAsNumpy()],
                    "outputs": [int(v) for v in op.OutputsAsNumpy()],
                    "options": flexbuffers.Loads(bytearray(op.CustomOptionsAsNumpy()))
                    if name == "TFLite_Detection_PostProcess"
                    else None,
                }
            )
    return {
        "inspection": "FlatBuffer only; no interpreter allocation or inference",
        "sha256": hashlib.sha256(data).hexdigest(),
        "size_bytes": len(data),
        "schema_version": model.Version(),
        "inputs": [tensor(int(i)) for i in graph.InputsAsNumpy()],
        "outputs": [tensor(int(i)) for i in graph.OutputsAsNumpy()],
        "tensor_dtype_counts": dict(
            Counter(types[graph.Tensors(i).Type()] for i in range(graph.TensorsLength()))
        ),
        "custom_ops": custom_ops,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--model", type=Path, default=ROOT / "models/ssd_mobilenet_v2_coco_quant.tflite"
    )
    args = parser.parse_args()
    print(json.dumps(inspect_model(args.model), indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
