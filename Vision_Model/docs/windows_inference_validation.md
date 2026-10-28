# Windows real TFLite inference validation

Validation date: 2026-10-25. This record describes **actual native Windows CPU
model allocation and inference**, superseding the Windows inference gaps in the
historical [implementation audit](implementation_audit.md). It does not establish
Raspberry Pi compatibility, classroom accuracy, response latency or deployment readiness.

## Runtime selected and installed

- Host: Windows 11 x86-64 (`Windows-11-10.0.26200-SP0`), **CPython 3.12.0**.
- Isolated environment: repository-local `.venv-inference`.
- Installed distributions: **tensorflow-cpu 2.16.2**, **tensorflow-intel 2.16.2**.
- Actual interpreter: `tensorflow.lite.python.interpreter.Interpreter`.
- Execution: CPU; two configured threads; default delegates disabled, matching the
  existing adapter policy. No GPU/TPU delegate or hardware optimization was introduced.
- Image libraries: NumPy **1.26.4**, Pillow **11.3.0**.

TensorFlow documents that native Windows CPU installation uses Intel's package;
PyPI provides the exact `tensorflow_intel-2.16.2-cp312-cp312-win_amd64.whl`.
Sources: [TensorFlow native Windows CPU installation](https://www.tensorflow.org/install/pip#windows-native),
[TensorFlow Intel 2.16.2 wheel](https://pypi.org/project/tensorflow-intel/2.16.2/),
[TensorFlow CPU 2.16.2](https://pypi.org/project/tensorflow-cpu/2.16.2/).
Actual local allocation and invocation, rather than wheel availability alone,
verify support for this model's custom postprocessing operator.

`requirements-windows-inference.txt` lists direct requirements;
`requirements-windows-inference-lock.txt` captures the complete resolved Windows
runtime environment used here. The latter is what the separate setup script
installs. Native Windows requires the Microsoft x64 Visual C++ Redistributable.
The Raspberry Pi requirements, setup script and YAML settings were not changed.
The lightweight development `.venv` still does not require TensorFlow.

## Actual model identity and allocation

Model: `models/ssd_mobilenet_v2_coco_quant.tflite` (6,741,896 bytes), the existing
pretrained CPU SSD MobileNetV2 COCO17 post-training-quantized artifact.
Its model bytes were not modified.

```text
SHA-256: 3438ee45f33153b1fe6c49e18bcd869ce7c94ef01c485d4eb027eaf8fc0db8ac
```

`create_detector(..., backend="tensorflow")` loaded these exact bytes and executed
`allocate_tensors()` successfully. The adapter then inspected the allocated
metadata and verified its configured input/output contract. Observed shapes:

| Graph position | Tensor index | Meaning | Actual allocated shape | Actual dtype |
| --- | --- | --- | --- | --- |
| Input 0 | 0 | RGB input | `[1,300,300,3]` | UINT8 |
| Output 0 | 252 | Scores | `[1,20]` | FLOAT32 |
| Output 1 | 250 | Boxes | `[1,20,4]` | FLOAT32 |
| Output 2 | 253 | Detection count | `[1]` | FLOAT32 |
| Output 3 | 251 | Classes | `[1,20]` | FLOAT32 |

Input name: `serving_default_input:0`. Observed input quantization:

```json
{
  "scale": 0.007843137718737125,
  "zero_point": 127,
  "scales": [0.007843137718737125],
  "zero_points": [127],
  "quantized_dimension": 0
}
```

Float outputs report quantization `(0.0, 0)` and empty quantization arrays.
The runtime operator list includes **`TFLite_Detection_PostProcess`**. Allocation
succeeded and subsequent actual invocations completed, so support is verified on
this Windows runtime. The graph output ordering agrees with configured positions
boxes=1, classes=3, scores=0, count=2. Output dimensions are read from allocation;
no expected detection capacity is substituted for observed output metadata.

The complete observed tensor names, shapes, signatures, dtypes, quantization arrays,
operator names, runtime identity and final invocation count are persisted in
[windows_allocated_tensors.json](windows_allocated_tensors.json) and
[the run metadata](../outputs/classroom_baseline/inference_metadata.json).
`models/inspection.json` remains the original static FlatBuffer record; its empty
serialized output shape arrays were not rewritten to pretend they are runtime data.

## Implemented preprocessing and outputs

The new nonrecursive image source discovers `.jpg`, `.jpeg` and `.png`
case-insensitively and sorts by `(filename.casefold(), filename)`. Pillow applies
EXIF orientation before converting to RGB. It keeps original full image resolution
for annotations and coordinate conversion. `SSDAdapter` bilinearly stretches a
separate view to the **actual allocated input dimensions**, currently 300x300.
The reviewed `raw_uint8` input mode supplies RGB bytes directly; no mean/std
normalization is applied. Input scale and zero point are checked against config.

The real interpreter runs once per successfully decoded image. The existing adapter
validates actual outputs, honors valid detection count, selects class **0** and
scores **>=0.55**, and retains normalized person boxes. Normalized edges are
converted to continuous pixels in the full-resolution **EXIF-oriented** image:
`xmin=xmin_normalized*width`, and likewise for other edges and centers. Values can
reach width/height at image edges. Rendering alone converts those edges to valid
inclusive pixel indices. Annotation occurs after inference on a copy, so overlay
pixels never enter the network.

CSV contains `image_filename`, 1-based `detection_index`, `class_name`, `class_id`,
`confidence`, pixel `xmin/ymin/xmax/ymax/center_x/center_y`, and six corresponding
`*_normalized` fields. JSON records image dimensions, source hash, EXIF orientation,
status, annotation path and detections, including empty detection lists for images
with no accepted persons. These are model predictions, not ground-truth labels.

Unreadable files are logged, recorded and skipped; batch exit code is 2 if any
occurred. Model/allocated-tensor/inference/output errors stop processing with exit
code 1 and preserve exact failure details and partial results. Missing CLI
arguments cause usage exit 2; a fully successful batch exits 0. Existing nonempty
output folders are refused, preserving prior evidence. No fake backend or fallback
model is available in the command.

## Actual sample-folder execution

The following command was executed from `Vision_Model`:

```powershell
.\.venv-inference\Scripts\python.exe -m src.main infer-images --input sample_images --output outputs/classroom_baseline --runtime tensorflow --overlay-zones
```

| Diagnostic count | Actual result |
| --- | --- |
| Images discovered | **27** |
| Images successfully processed | **27** |
| Images failed / unreadable | **0** |
| Images not attempted | **0** |
| Images with accepted person detections | **1** |
| Total accepted person detections | **1** |
| Successful real `invoke()` calls in this batch | **27** |
| Annotated images saved | **27** |
| Final status / process exit code | `completed` / **0** |

The one accepted prediction was in **`IMG_20261013_133640.jpg`**, with confidence
**0.5703125**, class ID **0**, in an oriented image of **3264x1836** pixels.
Its continuous pixel box was approximately
`(xmin=2712.935, ymin=1353.705, xmax=3020.201, ymax=1605.827)`.
The exact values are in CSV/JSON. No threshold was lowered and no detections were
invented or manually inserted. Images without accepted predictions remain in the
JSON with `detections: []`; they are not assertions of true vacancy.

Artifacts created:

- [Annotated image directory](../outputs/classroom_baseline/annotated/).
- [Example annotated prediction](../outputs/classroom_baseline/annotated/IMG_20261013_133640.jpg.annotated.jpg).
- [detections.csv](../outputs/classroom_baseline/detections.csv).
- [detections.json](../outputs/classroom_baseline/detections.json).
- [summary.json](../outputs/classroom_baseline/summary.json).
- [inference_metadata.json](../outputs/classroom_baseline/inference_metadata.json).
- [Captured execution log](../outputs/classroom_baseline/run.log).

All images are annotated copies; source JPEGs were not overwritten. The optional
polygons and banner are explicitly labelled **UNCALIBRATED**. They were projected
as diagnostic image overlays only. `config/zones.yaml` remains `calibrated:false`.
No occupancy state transitions, MQTT publisher, camera capture or appliance actions
are used in this offline path. `outputs/` is gitignored and remains available locally.
The compact captured runtime evidence under `docs/` can be versioned separately.

## Warnings and errors observed

No allocation errors, inference errors, unreadable source images or output-write
failures occurred in the sample batch. The run metadata records these caveats:

- Model predictions only; no ground truth, accuracy assessment or performance benchmark.
- At most the allocated SSD detection capacity (20 here) can be returned per full image.
- Zone overlay is UNCALIBRATED for these images; no occupancy decisions are made.

TensorFlow printed informational oneDNN floating-point round-off notices during
import. The real-inference tests emitted two protobuf/UPB `DeprecationWarning`s
about custom metaclass `tp_new` behavior becoming disallowed in Python 3.14;
this validated interpreter is Python 3.12. Neither warning is an allocation or
inference failure. No inference speed benchmark was performed or reported.

A diagnostic visual check confirmed that the annotation and uncalibrated labels
are rendered. The inspected image also contains a seated person without a box;
this is a qualitative concern for further coverage assessment, not a quantified
accuracy result or a completed ground-truth evaluation.

## Commands and validation actually executed

Runtime installation was performed with the equivalent explicit commands before
running the setup script itself:

```powershell
python -m venv .venv-inference
.\.venv-inference\Scripts\python.exe -m pip install --no-cache-dir --only-binary=:all: -r requirements-windows-inference.txt
.\scripts\setup_windows_inference.ps1
.\.venv-inference\Scripts\python.exe scripts/inspect_allocated_model.py --runtime tensorflow --output outputs/windows_allocation.json
.\.venv\Scripts\python.exe -m pytest -q -p no:cacheprovider
.\.venv-inference\Scripts\python.exe -m pytest tests/integration -q --run-real-inference -p no:cacheprovider
.\.venv-inference\Scripts\python.exe -m pytest -q --run-real-inference -p no:cacheprovider
.\.venv\Scripts\python.exe -m ruff check .
.\.venv\Scripts\python.exe -m ruff format --check .
.\.venv\Scripts\python.exe scripts/check_environment.py --static
.\.venv-inference\Scripts\python.exe -m pip check
```

Results: **117 unit/software tests passed** with **2 real-model tests deliberately
skipped** in the lightweight environment; with explicit opt-in, **all 119 tests
passed**, including the two actual model integration tests. The original **86 test
cases and their source files are preserved**; 31 software cases and 2 real-model
cases were added. The real tests are in `tests/integration/test_windows_inference.py`
and have no mocked outputs. One allocates/invokes the actual model and inspects
real tensors; the other invokes the real CLI on a generated image and validates
artifacts. The separate 27-photo run above supplies actual sample-folder evidence.

New software tests cover discovery, RGB conversion, EXIF rotation, pixel/normalized
coordinates, annotation copies, serialization, zero-detection images, corruption,
allocation/output failures, result preservation, CLI validation and avoiding MQTT.
Normal software tests still work without installing TensorFlow. Lint, formatting,
static model/config checks and pip dependency checks pass. The model, Pi runtime
requirements, camera code, occupancy code, MQTT code and both YAML files were
checked against pre-change hashes and remain unchanged.

## Remaining deployment blockers

Windows CPU inference for this model is now operational. It does not resolve:
physical quadrant calibration, actual Picamera2 operation, ARM runtime allocation,
seated/partially hidden/back-row and crowded-room detection coverage, camera
obstruction handling, existing ESP32 firmware integration, MQTT broker configuration,
clock/expiry/fallback behavior, the <=5-second arrival-to-action target, or the Pi's
512 MB resource/stability budget. A successful invocation and saved boxes do not
establish classroom suitability. The baseline's sparse accepted predictions need
review against labelled ground truth before any occupancy accuracy claim.
