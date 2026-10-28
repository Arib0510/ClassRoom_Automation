"""Isolated desktop NCNN kernel check; consumes prepared NCHW float32, never hardware."""

import argparse
from pathlib import Path

import ncnn
import numpy as np


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--param", type=Path, required=True)
    parser.add_argument("--bin", type=Path, required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise ValueError("Preserving existing NCNN output")
    tensor = np.load(args.input, allow_pickle=False)
    if tensor.dtype != np.float32 or tensor.ndim != 4 or tensor.shape[0:2] != (1, 3):
        raise ValueError("Expected prepared batch-one RGB NCHW float32")
    with ncnn.Net() as net:
        net.opt.num_threads = 2
        net.opt.use_vulkan_compute = False
        net.opt.use_fp16_packed = False
        net.opt.use_fp16_storage = False
        net.opt.use_fp16_arithmetic = False
        if net.load_param(str(args.param)) != 0 or net.load_model(str(args.bin)) != 0:
            raise RuntimeError("NCNN load failed")
        inputs, outputs = net.input_names(), net.output_names()
        if len(inputs) != 1 or len(outputs) != 1:
            raise ValueError(f"Review generated I/O: {inputs}, {outputs}")
        print(f"NCNN input={inputs[0]} output={outputs[0]}", flush=True)
        # clone owns native storage; no extractor holds a view into a temporary ndarray.
        native_input = ncnn.Mat(tensor[0]).clone()
        with net.create_extractor() as extractor:
            if extractor.input(inputs[0], native_input) != 0:
                raise RuntimeError("NCNN input rejected")
            status, mat = extractor.extract(outputs[0])
            if status != 0:
                raise RuntimeError(f"NCNN extract failed: {status}")
            result = np.array(mat).copy()
        if result.ndim == 2:
            result = result[None]
        np.save(args.output, result, allow_pickle=False)
        print(f"Saved {result.shape}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
