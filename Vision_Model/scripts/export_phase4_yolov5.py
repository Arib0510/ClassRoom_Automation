"""Desktop-only official v7 export plus ONNX/NCNN equivalence on real photographs."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from importlib.metadata import version
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import numpy as np  # noqa: E402

from src.experimental_detector import (  # noqa: E402
    REVISION,
    WEIGHT_SHA256,
    YOLOv5n,
    person_candidates,
    person_nms,
)
from src.person_labels import source_hash  # noqa: E402
from src.phase3_diagnostics import empty_output  # noqa: E402
from src.phase4_comparison import write_json  # noqa: E402


def equivalence(reference: np.ndarray, actual: np.ndarray) -> dict:
    if reference.shape != actual.shape:
        raise ValueError(f"Export output shape mismatch: {reference.shape} != {actual.shape}")
    expected = person_candidates(reference, 0.10, 0)
    expected = expected[person_nms(expected)]
    observed = person_candidates(actual, 0.10, 0)
    observed = observed[person_nms(observed)]
    same_shape = expected.shape == observed.shape
    postprocess_equal = same_shape and np.allclose(expected, observed, rtol=1e-4, atol=1e-3)
    return {
        "shape": list(actual.shape),
        "max_absolute_decoded_difference": float(np.max(np.abs(reference - actual))),
        "max_absolute_probability_difference": float(
            np.max(np.abs(reference[..., 4:] - actual[..., 4:]))
        ),
        "raw_allclose_rtol_1e4_atol_1e3": bool(
            np.allclose(reference, actual, rtol=1e-4, atol=1e-3)
        ),
        "person_predictions_reference": len(expected),
        "person_predictions_export": len(observed),
        "postprocess_allclose_rtol_1e4_atol_1e3": bool(postprocess_equal),
    }


def export_and_verify(output: Path, samples: list[Path]) -> dict:
    empty_output(output)
    output = output.resolve()
    summary = {
        "status": "processing",
        "source_revision": REVISION,
        "weight_sha256": WEIGHT_SHA256,
        "platform": sys.platform,
        "pi_tested": False,
        "dependencies": {p: version(p) for p in ("torch", "onnx", "onnxruntime", "pnnx", "ncnn")},
        "exports": [],
    }
    write_json(output / "export_verification.json", summary)
    try:
        import onnx
        import onnxruntime as ort
        import pnnx

        for size in (320, 416):
            adapter = YOLOv5n(size)
            from export import export_onnx, export_torchscript
            from models.yolo import Detect

            for module in adapter.model.modules():
                if isinstance(module, Detect):
                    module.inplace = False
                    module.dynamic = False
                    module.export = True
            tensor, _ = adapter.prepare(samples[0])
            with adapter.torch.inference_mode():
                adapter.model(tensor)
                adapter.model(tensor)
            file = output / f"yolov5n_{size}.pt"
            onnx_result = export_onnx(
                adapter.model, tensor, file, opset=12, dynamic=False, simplify=False
            )
            if onnx_result[0] is None:
                raise RuntimeError("Official ONNX export failed; see export log")
            onnx_path = Path(onnx_result[0])
            onnx.checker.check_model(onnx.load(onnx_path))
            ts_result = export_torchscript(adapter.model, tensor, file, optimize=False)
            if ts_result[0] is None:
                raise RuntimeError("Official TorchScript export failed")
            script_path = Path(ts_result[0])
            command = [
                pnnx.EXEC_PATH,
                str(script_path),
                f"inputshape=[1,3,{size},{size}]",
                "device=cpu",
                "fp16=0",
            ]
            with (output / f"pnnx_{size}.log").open("w", encoding="utf-8") as log:
                subprocess.run(
                    command, cwd=output, stdout=log, stderr=subprocess.STDOUT, check=True
                )
            stem = script_path.with_suffix("")
            param = Path(str(stem) + ".ncnn.param")
            binary = Path(str(stem) + ".ncnn.bin")
            options = ort.SessionOptions()
            options.intra_op_num_threads = 2
            session = ort.InferenceSession(
                str(onnx_path), options, providers=["CPUExecutionProvider"]
            )
            entry = {
                "size": size,
                "onnx_opset": 12,
                "ncnn_storage": "FP32",
                "ncnn_runtime": "isolated process; discover input/output names from loaded graph",
                "samples": [],
                "pnnx_command": command,
                "artifacts": [
                    {"file": p.name, "bytes": p.stat().st_size, "sha256": source_hash(p)}
                    for p in (onnx_path, script_path, param, binary)
                ],
            }
            for sample in samples:
                tensor, metadata = adapter.prepare(sample)
                with adapter.torch.inference_mode():
                    reference = adapter.model(tensor)[0].cpu().numpy()
                onnx_raw = session.run(None, {session.get_inputs()[0].name: tensor.numpy()})[0]
                prepared = output / f"input_{size}_{sample.name}.npy"
                native_output = output / f"ncnn_{size}_{sample.name}.npy"
                np.save(prepared, tensor.numpy(), allow_pickle=False)
                worker = [
                    sys.executable,
                    str(ROOT / "scripts/infer_phase4_ncnn.py"),
                    "--param",
                    str(param),
                    "--bin",
                    str(binary),
                    "--input",
                    str(prepared),
                    "--output",
                    str(native_output),
                ]
                with (output / f"ncnn_{size}_{sample.name}.log").open("w") as log:
                    subprocess.run(
                        worker, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120
                    )
                ncnn_raw = np.load(native_output, allow_pickle=False)
                comparisons = {
                    "onnx": equivalence(reference, onnx_raw),
                    "ncnn": equivalence(reference, ncnn_raw),
                }
                entry["samples"].append(
                    {
                        "file_name": sample.name,
                        "source_sha256": source_hash(sample),
                        "preprocessing": metadata,
                        **comparisons,
                    }
                )
                np.savez_compressed(
                    output / f"equivalence_{size}_{sample.name}.npz",
                    pytorch=reference,
                    onnx=onnx_raw,
                    ncnn=ncnn_raw,
                )
            entry["equivalent_on_samples"] = all(
                s[r][k]
                for s in entry["samples"]
                for r in ("onnx", "ncnn")
                for k in (
                    "raw_allclose_rtol_1e4_atol_1e3",
                    "postprocess_allclose_rtol_1e4_atol_1e3",
                )
            )
            summary["exports"].append(entry)
            write_json(output / "export_verification.json", summary)
        summary["status"] = "completed"
        summary["all_equivalent"] = all(e["equivalent_on_samples"] for e in summary["exports"])
    except Exception as exc:
        summary.update(status="failed", error=f"{type(exc).__name__}: {exc}")
        write_json(output / "export_verification.json", summary)
        raise
    write_json(output / "export_verification.json", summary)
    return summary


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output", type=Path, default=Path("outputs/phase4_model_comparison/exports")
    )
    parser.add_argument(
        "--samples",
        nargs="+",
        type=Path,
        default=[
            Path("sample_images/IMG_20261013_133640_1.jpg"),
            Path("sample_images/IMG_20261013_133833.jpg"),
            Path("sample_images/IMG_20261013_134008.jpg"),
        ],
    )
    args = parser.parse_args(argv)
    result = export_and_verify(args.output, args.samples)
    print(json.dumps({"status": result["status"], "all_equivalent": result["all_equivalent"]}))
    return 0 if result["all_equivalent"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
