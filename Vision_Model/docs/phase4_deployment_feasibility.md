# Phase 4: Pi Zero 2 W deployment feasibility

## Decision and evidence boundary

**A lightweight NCNN conversion path exists for this exact YOLOv5n checkpoint.**
ONNX and NCNN FP32 exports were executed and checked on Windows. A CPython 3.11
ARMv7 Linux NCNN wheel exists and was inspected without installing it on a Pi.
This is sufficient to propose an isolated target-runtime smoke test. It is not
evidence of acceptable classroom coverage, target allocation, 512 MB suitability
or ≤5-second arrival-to-appliance activation.

Actual detection evidence argues **against production replacement**: YOLOv5n
416 at 0.10 gives 3 TP / 8 FP / 51 FN on 54 annotated instances. Its best F1 is
0.0923, below SSD overlap's 0.3023. The latter requires four passes and also has
poor coverage. See [the comparison](phase4_model_comparison.md).

The [Pi Zero 2 W hardware specification](https://www.raspberrypi.com/products/raspberry-pi-zero-2-w/)
states a 1 GHz quad-core Cortex-A53 and 512 MB SDRAM. Its CPU can execute 64-bit
instructions, but the requested **Bookworm 32-bit userland requires ARMv7/armhf
libraries and CPython 3.11 bindings**. An aarch64 wheel or Pi 4/5 benchmark does
not establish compatibility or timing for this deployment.

## Exact source and formats tested

- Official [YOLOv5 source](https://github.com/ultralytics/yolov5/tree/915bbf294bb74c859f0b41f1c23bc395014ea679),
  v7.0, commit `915bbf294bb74c859f0b41f1c23bc395014ea679`.
- Official [yolov5n.pt](https://github.com/ultralytics/yolov5/releases/download/v7.0/yolov5n.pt),
  SHA `4f180cf23ba0717ada0badd6c685026d73d48f184d00fc159c2641284b2ac0a3`.
- Export environment: native Windows x86-64, Python 3.12.0, Torch 2.5.1+cpu,
  ONNX 1.17.0, ONNX Runtime 1.20.1, PNNX 20250530, NCNN 1.0.20250503.
- Original checkpoint parameters: 1,872,157; official fused model: 1,867,405.
  Weights occupy 4,062,133 bytes; that checkpoint storage is not the FP32 model's
  RAM requirement.

The pinned [v7.0 export implementation](https://github.com/ultralytics/yolov5/blob/915bbf294bb74c859f0b41f1c23bc395014ea679/export.py)
supports ONNX and TorchScript, among other formats. **It does not expose an NCNN
export option.** This experiment uses its official ONNX/TorchScript functions,
then PNNX to convert that TorchScript graph into NCNN. No newer YOLO family,
current Ultralytics export wrapper or different checkpoint was substituted.
The [PNNX documentation](https://github.com/pnnx/pnnx#how-to-use-pnnx) describes
TorchScript-to-NCNN conversion. All converter work remains on Windows.

## Measured artifact sizes

All values below are actual file sizes, not estimated runtime memory:

| Artifact | 320 square, bytes | 416 square, bytes |
| --- | --- | --- |
| Official `.pt`, shared checkpoint | 4,062,133 | 4,062,133 |
| ONNX, opset 12 FP32, no embedded NMS | 7,618,951 | 7,688,503 |
| Official TorchScript FP32 | 7,845,923 | 7,888,069 |
| NCNN `.param` | 16,883 | 16,883 |
| NCNN `.bin`, FP32 | 7,570,660 | 7,640,212 |
| NCNN param + bin | 7,587,543 | 7,657,095 |
| Existing SSD quantized TFLite | 6,741,896 | 6,741,896 |

[export_verification.json](../outputs/phase4_model_comparison/exports/export_verification.json)
records each checksum, converter command, version, sample and difference. Generated
model sizes differ by resolution because static detection-grid constants are
included. TorchScript serialization bytes can differ across fresh exports;
validate newly generated artifacts instead of assuming a historical export hash.
The original downloaded weight checksum remains fixed.

## Reproducible desktop export and equivalence

From the repository root, after environment setup and real comparison:

```powershell
.\scripts\setup_windows_yolov5.ps1
.\.venv-yolov5\Scripts\python.exe scripts/export_phase4_yolov5.py --output outputs/phase4_export_repeat
```

The script refuses nonempty destinations. It verifies upstream source/weights,
sets standard Detect export flags in memory, performs the official fixed-size
ONNX opset-12 export and TorchScript trace, and invokes the installed pinned
PNNX executable, equivalent to:

```powershell
.\.venv-yolov5\Scripts\pnnx.exe outputs/phase4_export_repeat/yolov5n_320.torchscript 'inputshape=[1,3,320,320]' device=cpu fp16=0
.\.venv-yolov5\Scripts\pnnx.exe outputs/phase4_export_repeat/yolov5n_416.torchscript 'inputshape=[1,3,416,416]' device=cpu fp16=0
```

These standalone converter commands are illustrative alternatives to the wrapper;
do not rerun them over preserved generated files. The wrapper calls the actual
PNNX executable path recorded in the verification JSON. Output graph names are
discovered from the loaded NCNN graph rather than inferred from filenames. The
generated graphs expose `in0` and `out0`, with decoded outputs `[1,6300,85]` and
`[1,10647,85]` after restoring the omitted NCNN batch dimension.

Both runtimes executed CPU kernels on these real photographs:

1. `IMG_20261013_133640_1.jpg` — accepted person predictions at both sizes.
2. `IMG_20261013_133833.jpg` — a 320 person candidate and no 416 candidate.
3. `IMG_20261013_134008.jpg` — no accepted person predictions at either size.

For all **six size/sample pairs**, both ONNX Runtime and NCNN pass decoded-output
and person-postprocessing `allclose(rtol=1e-4, atol=1e-3)` against real PyTorch
outputs. Across these checks the largest decoded absolute difference is
**0.00166321 input pixels** for ONNX and **0.00124359** for NCNN; largest
probability differences are approximately **6.23e-6** and **8.11e-6** respectively.
Relative tolerance also applies; this is numerical equivalence within the stated
tolerance, not bit equality. Retained person counts agree. Raw NPZ comparisons,
prepared NPY inputs and per-worker logs remain beside the models.

The first NCNN attempt terminated natively after its first sample without a
Python exception. Its files/logs remain under `exports_native_failed_01/`. The
successful path uses explicit owned `ncnn.Mat(...).clone()` input storage and
isolates NCNN from PyTorch in a child process. The exact cause of the first
native termination was not established. No claim is made that process isolation
is necessary on the Pi. The default experimental worker is a contract probe;
starting a process/loading weights per frame would need separate latency analysis.

## ARMv7 runtime and native-library evidence

The [pinned NCNN package files](https://pypi.org/project/ncnn/1.0.20250503/#files)
include:

```text
ncnn-1.0.20250503-cp311-cp311-manylinux_2_31_armv7l.whl
```

This wheel was downloaded only for inspection on Windows, and its hash checked
against the PyPI file record:

- File size: **2,912,627 bytes**.
- SHA: `c9cafa5ee10ee1921e243904e2cfe5911ab5fc405310f41d67f3b88bc34bb21e`.
- Binding: `ncnn/ncnn.cpython-311-arm-linux-gnueabihf.so`.
- ELF class: **ELF32**, machine **40 (ARM)**, flags **0x05000400**, including
  the ARM hard-float ABI flag. Bundled OpenMP library is also ELF32 ARM.
- Declared platform baseline is Linux ARMv7, glibc ≥2.31; actual target loading,
  symbol compatibility and instruction execution were not tested.

Direct native dependencies inspected from its ELF dynamic section:
`libgomp-39027b09.so.1.0.0` (bundled), `libpthread.so.0`, `libdl.so.2`,
`libstdc++.so.6`, `libm.so.6`, `libgcc_s.so.1`, `libc.so.6` and
`ld-linux-armhf.so.3`. Full evidence is in
[ncnn_armv7_inspection.json](../outputs/phase4_inspection/ncnn_armv7_inspection.json).
The wheel was not installed on the Pi or used to claim ARM inference success.

Package metadata declares NumPy, tqdm, requests, portalocker and opencv-python.
The minimal `ncnn` import loads the native binding; helper/model-zoo modules have
broader dependencies. A normal pip install would pull those dependencies, which
does not meet this project's lightweight Pi dependency policy. **No change to
`requirements-pi.txt` was made.** A future isolated core-kernel probe may install
the inspected wheel with `--no-deps` after checking NumPy and native libraries;
that is deliberately a limited test environment, not a fully dependency-satisfied
production package. Validate packaging and import behavior on the target before
choosing a Python integration. A small native C++ binding is another option.

For comparison, the inspected [ONNX Runtime 1.20.1 files](https://pypi.org/project/onnxruntime/1.20.1/#files)
include CPython 3.11 aarch64 Linux wheels but **no ARMv7 Linux wheel**. The
[ONNX Runtime build documentation](https://onnxruntime.ai/docs/build/inferencing.html)
describes Arm source/cross compilation. The Windows ONNX result therefore does
not provide a ready 32-bit Pi installation; a native build and dependency/RAM
audit would be necessary. NCNN is the more concrete tested lightweight path here.

## Native build fallback, not executed

If the ARMv7 wheel fails or its packaging is unsuitable, the pinned NCNN source
has a Pi 3/ARMv7 NEON hard-float toolchain and Python bindings. The verified source
tag `20250503` resolves to **`305837fd4a722ebc47c5d72e72d8ec9ae970e932`**.
The [pinned toolchain](https://github.com/Tencent/ncnn/blob/305837fd4a722ebc47c5d72e72d8ec9ae970e932/toolchains/pi3.toolchain.cmake)
uses ARMv7, NEON and hard-float; this is source architecture evidence, not a build
tested on Zero 2 W. The [build instructions](https://github.com/Tencent/ncnn/wiki/how-to-build)
describe the CMake process. A CPU-only native-library build blueprint is:

```bash
# Future target/toolchain work only; not executed in Phase 4.
git clone --recursive https://github.com/Tencent/ncnn.git ncnn-phase4
git -C ncnn-phase4 checkout 305837fd4a722ebc47c5d72e72d8ec9ae970e932
git -C ncnn-phase4 submodule update --init --recursive
cmake -S ncnn-phase4 -B ncnn-phase4/build-armhf \
  -DCMAKE_BUILD_TYPE=Release -DNCNN_VULKAN=OFF \
  -DNCNN_BUILD_TOOLS=OFF -DNCNN_BUILD_EXAMPLES=OFF \
  -DNCNN_BUILD_BENCHMARK=OFF -DNCNN_BUILD_TESTS=OFF \
  -DCMAKE_C_FLAGS='-mcpu=cortex-a53 -mfpu=neon-vfpv4 -mfloat-abi=hard' \
  -DCMAKE_CXX_FLAGS='-mcpu=cortex-a53 -mfpu=neon-vfpv4 -mfloat-abi=hard'
cmake --build ncnn-phase4/build-armhf -j1
```

This assumes native **32-bit armhf GCC/G++** and CMake, not an x86 compiler with
Arm flags. Cross builds require an armhf compiler/sysroot and adapted toolchain.
Python bindings additionally require `NCNN_PYTHON=ON`, matching Python 3.11
development headers and the pybind11 submodule; wheel construction/install paths
must be verified for that build. C++ integration avoids Python bindings but still
needs image preprocessing and postprocessing. Prefer building on a larger
machine/cross toolchain: a 512 MB Pi may not accommodate compilation comfortably.
No compiler, heavy framework or build was installed/run on a Pi in this phase.

## Packaging and future isolated smoke test

Create byte-verified test packages from preserved exports:

```powershell
.\.venv-yolov5\Scripts\python.exe scripts/analyze_phase4.py --output outputs/phase4_package_repeat
```

Existing packages are under
`outputs/phase4_model_comparison/analysis/deployment_packages/{320,416}/`.
Each includes only the NCNN param/bin, checksum inventory, label/preprocessing
contract, upstream GPL license, one desktop-prepared NPY input and a kernel worker.
No PyTorch, ONNX converter, camera or appliance-control implementation is packaged.
Keep the corresponding pinned upstream source/license record accessible for
license compliance; a local package is not a redistribution clearance.

After a separate decision to perform Pi testing, an operator could verify OS/ABI,
create an isolated environment, inspect/install the matching NCNN core binding,
verify package checksums, and run **a saved input** with no camera or MQTT:

```bash
# Future target operation; not run here. Run inside the copied 416 test package.
python3.11 infer_phase4_ncnn.py \
  --param yolov5n_416.ncnn.param --bin yolov5n_416.ncnn.bin \
  --input prepared_input.npy --output pi_output.npy
```

Compare the result with the desktop decoded reference before performance tests.
The worker discovers I/O names and owns its input memory. This is not the
production detector adapter. It does not perform image decoding, letterbox or
person postprocessing on the Pi; a lightweight target implementation of those
steps must pass coordinate and recognition equivalence before live use. Pillow
bilinear and NCNN-native resize must not be assumed identical to the tested
OpenCV INTER_LINEAR preprocessing. Full Python model-zoo helpers are unnecessary
for the saved-input probe and should not silently introduce OpenCV/PyTorch.

## Quantization and alternative formats

The current NCNN artifacts use **FP32**, `fp16=0`. No INT8 or FP16 accuracy,
resource or target-speed result is claimed. NCNN provides
[post-training INT8 calibration tools](https://github.com/Tencent/ncnn/wiki/quantized-int8-inference).
They require representative, correctly preprocessed calibration inputs and a
fresh detection evaluation after conversion; model-size reduction is not proof of
faster or accurate target execution. This phase did not train or quantize.

Official v7.0 also has TFLite export through TensorFlow conversion. That is
desktop tooling, not permission to install TensorFlow on the Pi. This checkpoint
was not converted/tested with TFLite here; TensorFlow export compatibility,
operator support, quantization calibration and tflite-runtime 2.14/Python 3.11
allocation remain unverified. TorchScript itself needs a PyTorch/libtorch
runtime and is not proposed for this 512 MB 32-bit deployment. ONNX is useful as
an interchange/reference format even while its target runtime path is unresolved.

## Memory, passes and timing constraints

YOLO requires **one forward pass per frame** at the selected resolution; the
comparison runs at two resolutions are alternatives, not two required live
passes. SSD full/ROI require one pass, left/right two and overlap four.
Threshold sweeps add no model execution. Both models require image preparation
and host postprocessing in addition to forward inference.

The following are calculated tensor storage amounts, **not RSS measurements**:

| FP32 tensor | 320 bytes | 416 bytes |
| --- | --- | --- |
| RGB NCHW input | 1,228,800 | 2,076,672 |
| Decoded `[1,N,85]` output | 2,142,000 | 3,619,980 |

Runtime activations/workspaces, thread stacks, allocators, Python/NumPy, image
decoding, camera buffers, OS memory and graph loading add to these amounts.
Production images are 640×480, whereas these source photos are 3264×1836; their
framing, detail and memory behavior are not interchangeable. File size alone
cannot establish 512 MB suitability. Preserve bounded frames, stale handling and
MQTT expiry in any later prototype.

No inference latency, peak RAM, power or thermal measurements were taken on the
Pi. The original 4-second observation freshness setting and two-hit/0.5-second
arrival debounce also matter. The end-to-end budget includes capture waiting,
preprocessing, model pass(es), postprocessing, debounce, Wi-Fi/MQTT and controller
appliance response. Fast desktop/export timing or a single Pi invoke would not
prove arrival-to-activation ≤5 seconds. Sustained operation and freshness must
also be measured. No Pi 4/5 results were used as Zero 2 W timing evidence.

## Remaining blockers and next step

1. Recognition is the primary blocker: YOLOv5n 320/416 is not an improvement over
   SSD cropping on this set. Improve/verify the evaluation dataset and visible
   box/attribute policy before investing in production replacement.
2. Reliable four-zone labels and mounted calibration are absent. No operational
   zone accuracy can be calculated from these illustrative image polygons.
3. ARMv7/Python 3.11 runtime loading, model execution, preprocessing equivalence,
   RAM and sustained thermal behavior require actual target tests.
4. The wheel's broad dependency metadata requires an explicit lightweight
   packaging choice; target integration has not been written or approved.
5. The first NCNN native failure is preserved; the successful owned-memory,
   isolated-process path must not be assumed to solve every target issue.
6. Power, camera capture/failures, MQTT delivery and appliance response remain
   unverified. Real appliance control stays disabled.

If hardware feasibility work proceeds, **YOLOv5n 416 NCNN FP32** is the alternative
export candidate, tested first on saved inputs alongside the unchanged SSD
single-pass resource baseline. It is not the selected production detector.
The evidence supports keeping production unchanged and prioritizing recognition
and physical-zone ground truth before appliance commissioning.
