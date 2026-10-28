# Phase 4: classroom person detection comparison

## 1. Executive summary

Real Windows CPU inference on all **27 original photographs**, at both **320×320
and 416×416**, does **not** support replacing SSD with official pretrained YOLOv5n.
At its best tested F1/recall setting, YOLOv5n 416 at 0.10 achieves **3 TP, 8 FP,
51 FN**, precision **0.2727**, recall **0.0556**, F1 **0.0923**. SSD overlapping
crops at its best F1 setting, 0.40, achieves **13 TP, 19 FP, 41 FN**, precision
**0.4063**, recall **0.2407**, F1 **0.3023**. Neither provides acceptable evidence
for unattended classroom occupancy automation.

YOLOv5n's best seated recall is **3/52 = 0.0577**, versus SSD overlap's **12/52 =
0.2308** at best F1 and **15/52 = 0.2885** at maximum recall. These are person
instance metrics on this small, related classroom photo collection, with visible
extent boxes and IoU ≥0.50. They are not an independent estimate of real-world
performance, a unique-person census, or physical-zone accuracy.

ONNX and NCNN FP32 exports pass desktop numerical/postprocessing equivalence on
three real photographs at both sizes. That establishes a conversion path, not
Pi deployment readiness. Pi Zero 2 W latency, RAM, power, temperature, camera,
MQTT, appliance response and the ≤5-second arrival target remain unmeasured.

## 2. Repository protection and scope

Initial Git HEAD existed: `ec2a5edb8ae338a737012e2061b3869b38409262`.
Initial untracked content was `sample_images/` and
`evaluation_baseline/ssd_run02_predictions.json`. No reset, automatic commit or
push was performed. Existing source photographs, labels, SSD weights/cache and
all Phase 3 evaluation artifacts are preserved. Original production modules,
active configuration, Pi requirements and `.venv-inference` dependencies are unchanged.

Read the requested project documents, source modules, test inventory and model
records before implementing separate experimental modules. `.gitignore` excludes
the experimental environment/source/weights/cache; `MANIFEST.in` excludes cloned
upstream source/cache from source distributions. No heavyweight experimental
dependency was added to the project/Pi runtime dependency list. The default
SSD threshold remains 0.55 and both calibration examples remain false.

The original software suite was **224 passed, 3 deliberately skipped**. Final
checks and protection hashes are in
[validation/evidence.json](../outputs/phase4_model_comparison/validation/evidence.json).
The protection inventory is
[protected_inventory.json](../outputs/phase4_inspection/protected_inventory.json).
No camera, broker, ESP32, service, training process or appliance was used.

## 3. Exact model identities and provenance

| Property | SSD baseline | YOLO experiment |
| --- | --- | --- |
| Identity | Coral TF2 SSD MobileNetV2 COCO17 PTQ, CPU | Official Ultralytics YOLOv5n COCO detection, v7.0 |
| Source revision | `104342d2d3480b3e66203073dac24f4e2dbb4c41` | `915bbf294bb74c859f0b41f1c23bc395014ea679` |
| File | `models/ssd_mobilenet_v2_coco_quant.tflite` | `models/experimental/yolov5n/yolov5n.pt` |
| Bytes | 6,741,896 | 4,062,133 |
| Input | UINT8 NHWC `[1,300,300,3]`, RGB raw bytes | FP32 NCHW `[1,3,S,S]`, RGB /255; S=320 or 416 |
| Verified person ID | 0 in the pinned SSD label file | 0 in the actual checkpoint's own 80-class map |
| Preprocessing | Original bilinear stretch/crop reprojection | Official letterbox, aspect preserved, 114 RGB padding, `auto=False` |
| Output | scores=0, boxes=1, count=2, classes=3 | Decoded `[1,N,85]`: xywh, objectness, 80 probabilities |
| Quantization | Existing UINT8 input and quantization checks preserved | FP32 CPU execution; no quantization applied |
| License record | Apache-2.0 in existing provenance | Pinned v7.0 source GPL-3.0, copied unchanged |

SSD SHA-256: `3438ee45f33153b1fe6c49e18bcd869ce7c94ef01c485d4eb027eaf8fc0db8ac`.
YOLO SHA-256: `4f180cf23ba0717ada0badd6c685026d73d48f184d00fc159c2641284b2ac0a3`.

The [official v7.0 weight URL](https://github.com/ultralytics/yolov5/releases/download/v7.0/yolov5n.pt)
and [exact source](https://github.com/ultralytics/yolov5/tree/915bbf294bb74c859f0b41f1c23bc395014ea679)
are recorded in [the experimental manifest](../models/experimental/yolov5n/manifest.json).
The hash was computed from downloaded bytes, not invented or presented as an
upstream signed checksum. Measured parameters: **1,872,157 checkpoint** and
**1,867,405 fused**. The architecture has depth multiplier 0.33, width multiplier
0.25, C3/SPPF blocks and three anchored detection heads, as saved in the manifest.
Keep GPL notices and applicable corresponding-source obligations in mind before
redistribution; no separate permissive weight-license exception was established.

## 4. Environments and acquisition evidence

All environments are local native Windows x86-64 / CPython **3.12.0**:

- `.venv`: lightweight software checks, no PyTorch/TensorFlow inference dependency.
- `.venv-inference`: unchanged TensorFlow CPU/Intel **2.16.2**, used only to rerun
  the three existing real SSD tests. Comparison uses the saved SSD cache.
- `.venv-yolov5`: runtime `torch 2.5.1+cpu`, `torchvision 0.20.1+cpu`, NumPy
  **1.26.4**, Pillow **11.3.0**, PyYAML **6.0.3**, OpenCV **4.10.0.84**; exports
  use ONNX **1.17.0**, ONNX Runtime **1.20.1**, PNNX **20250530**, NCNN
  **1.0.20250503**. CPU execution uses two Torch threads.

Exact distributions, including indirect dependencies, are in
[requirements-windows-yolov5-lock.txt](../requirements-windows-yolov5-lock.txt).
The direct requirements and setup script are separate from Pi requirements.
The PyTorch CPU index initially failed DNS resolution (`getaddrinfo failed`);
pinned PyPI Windows wheels installed successfully and identify as CPU builds at
runtime. PowerShell `Invoke-WebRequest` initially failed authentication; Python
HTTPS retrieval from the same official weight URL succeeded. No alternate
checkpoint was substituted.

## 5. Human ground truth and baseline verification

All **27/27** records are reviewed by **Arib**. Each image is **3264×1836** after
orientation and has two certain person annotations: **54 instances**, no uncertain
labels. Original source hashes/dimensions/inventory match the human labels and
SSD cache. The baseline labels and prediction cache are byte-identical to their
counterparts in `outputs/phase3_diagnostics/evaluated_run_02/`; this directory
also contains the real evaluation artifacts absent from `evaluation_baseline/`.

Label SHA: `22ea3e8bddf3a2ec76b3a7a4cac5b02d05d4ed5f4f5dbf191f375a9aa07aefee`.
SSD cache SHA: `0b46e7d0c918978b8668a288ed8c067d158bc065332dad718cfc00e4acd78f36`.
All **24** SSD mode/threshold TP/FP/FN totals and prediction counts were recomputed
using the existing evaluator and checked against the saved summary; all match.
See [baseline_verification.json](../outputs/phase4_model_comparison/baseline_verification.json).

## 6. Common preprocessing and evaluation contract

`src.experimental_detector` provides a common record interface and a cached SSD
adapter without changing the production SSD interface. Each YOLO record includes
filename/model/class, full precision confidence, normalized and continuous pixel
xyxy, original/input dimensions and preprocessing metadata. Pillow performs EXIF
orientation and RGB conversion; OpenCV letterbox resize/padding preserves those
RGB channels. No extra RGB/BGR swap is applied.

Both supported input sizes are stride-32 compatible. Actual decoded shapes are
`[1,6300,85]` at 320 and `[1,10647,85]` at 416. Best class is selected before the
person filter, score is objectness × class probability, and stable person NMS
suppresses IoU **>0.45**, capped at 300. Threshold comparison is inclusive `>=`;
upstream's strict `>` differs only exactly on the cutoff. All **54 saved decoded
outputs** agree with official v7.0 postprocessing at the evaluation floor.

Letterbox inversion uses the returned ratio and fractional pad, clips to original
edges and retains continuous coordinates. Boxes entirely in padding are excluded.
No coordinate rounding or overlapping YOLO tiling was used. Raw decoded arrays
and pre-NMS person candidates remain in `raw/<model>/`; model JSON preserves
zero-detection images. There was exactly one comparison forward pass per
image/resolution (**54 total**); all six threshold sweeps reuse these predictions.
Integration/export checks are separate additional kernel executions.

The unchanged `person_labels.match_image` performs score-greedy, one-to-one
matching at **IoU ≥0.50**, choosing the greatest overlap among unmatched certain
labels; uncertain overlaps are ignored after certain matching. Precision is
TP/(TP+FP), recall TP/(TP+FN), F1 2TP/(2TP+FP+FN); zero denominators are null.
Prediction counts are not true-positive counts. SSD full/ROI preserve their own
postprocessing; left/right and overlap retain the original global NMS at ≥0.50.

## 7. Person-level accuracy and threshold sensitivity

Each row uses all 54 certain labels. The full 36-row table is in
[summary.md](../outputs/phase4_model_comparison/summary.md), with
[comparison.csv](../outputs/phase4_model_comparison/comparison.csv) and
[precision_recall.csv](../outputs/phase4_model_comparison/precision_recall.csv).

| Configuration | Threshold | TP | FP | FN | Precision | Recall | F1 | Images with predictions | Images with misses |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| SSD full | 0.10–0.40 | 2 | 2 | 52 | 0.5000 | 0.0370 | 0.0690 | 2 | 27 |
| SSD ROI | 0.10–0.40 | 2 | 4 | 52 | 0.3333 | 0.0370 | 0.0667 | 3 | 27 |
| SSD left/right | 0.40 | 4 | 1 | 50 | 0.8000 | 0.0741 | 0.1356 | 5 | 27 |
| SSD overlap | 0.10/0.20 | 16 | 40 | 38 | 0.2857 | 0.2963 | 0.2909 | 23 | 25 |
| SSD overlap, max recall with fewer FP | 0.30 | 16 | 37 | 38 | 0.3019 | 0.2963 | 0.2991 | 23 | 25 |
| SSD overlap, best F1 | 0.40 | 13 | 19 | 41 | 0.4063 | 0.2407 | 0.3023 | 21 | 25 |
| SSD overlap | 0.55 | 4 | 2 | 50 | 0.6667 | 0.0741 | 0.1333 | 5 | 27 |
| YOLOv5n 320, best F1/recall | 0.10 | 2 | 3 | 52 | 0.4000 | 0.0370 | 0.0678 | 5 | 27 |
| YOLOv5n 320 | 0.20 | 1 | 1 | 53 | 0.5000 | 0.0185 | 0.0357 | 2 | 27 |
| YOLOv5n 320 | 0.30 | 1 | 0 | 53 | 1.0000 | 0.0185 | 0.0364 | 1 | 27 |
| YOLOv5n 320 | 0.40/0.50/0.55 | 0 | 0 | 54 | undefined | 0 | 0 | 0 | 27 |
| YOLOv5n 416, best F1/recall | 0.10 | 3 | 8 | 51 | 0.2727 | 0.0556 | 0.0923 | 6 | 27 |
| YOLOv5n 416 | 0.20/0.30 | 2 | 0 | 52 | 1.0000 | 0.0370 | 0.0714 | 2 | 27 |
| YOLOv5n 416 | 0.40 | 1 | 0 | 53 | 1.0000 | 0.0185 | 0.0364 | 1 | 27 |
| YOLOv5n 416 | 0.50/0.55 | 0 | 0 | 54 | undefined | 0 | 0 | 0 | 27 |

Best-F1 ties are resolved by greater precision, then greater threshold. For SSD
maximum recall, 0.30 has the same 16 TP as 0.10/0.20 with three fewer FP. Reducing
YOLO 416's cutoff from 0.20 to 0.10 adds **one TP and eight FP**. A precision of 1
at 0.20/0.30 is based on only two accepted predictions and 52 misses. It does not
make that setting a suitable occupancy detector.

![Precision-recall overview](../outputs/phase4_model_comparison/analysis/precision_recall_overview.png)

## 8. Per-image findings and missed student cases

[per_image.csv](../outputs/phase4_model_comparison/per_image.csv) contains all
**972 image/configuration/threshold rows**, including precision/recall where
defined. [per_image_best.csv](../outputs/phase4_model_comparison/analysis/per_image_best.csv)
lists all 27 images at family best F1; every FN annotation ID is retained in the
evaluation JSON. [person_cases.csv](../outputs/phase4_model_comparison/person_cases.csv)
compares all 54 individual labels.

At the selected settings, only **two instances match in both models**; SSD alone
matches **11**, YOLO alone **one**, and **40** are missed by both. SSD fully
matches both people only in `IMG_20261013_133939.jpg` and
`IMG_20261013_133947.jpg`; YOLO misses at least one person in all 27 images.
The single YOLO-only match is annotation **10** in `IMG_20261013_133831_1.jpg`.

All tilted photographs `134007.jpg`, `134008.jpg`, `134009.jpg`, `134009_1.jpg`
miss both people in both selected models; `134007_1.jpg` has one SSD TP and no
YOLO TP. `133833.jpg` has two SSD FP and two FN; YOLO returns no accepted box and
two FN. These examples show persistent misses across pose/position changes,
without assigning unsupported physical-zone or distant-person attributes.

## 9. Seated, partial, distant and desk-occluded annotations

The existing flags are **present**, not missing: `uncertain:false` for 54,
`partial:false` for 54, `seated:true` for 52 and `seated:false` for two. Phase 3's
`partial_seated_actual` means **partial AND seated**, explaining its zero even
though 52 labels are seated. It is not an inventory of every seated annotation.

| Setting | Seated matches / 52 | Seated recall |
| --- | --- | --- |
| SSD full at 0.10 | 2 | 0.0385 |
| SSD left/right at 0.40 | 3 | 0.0577 |
| SSD overlap at 0.30 | 15 | 0.2885 |
| SSD overlap at 0.40 | 12 | 0.2308 |
| YOLOv5n 320 at 0.10 | 1 | 0.0192 |
| YOLOv5n 416 at 0.10 | 3 | 0.0577 |

Partial and partial-seated recall are **NOT AVAILABLE**: no positive partial
labels exist. This proves that category is absent from the label file, not that
there are physically no partially visible people. Visual review shows desk-hidden
lower bodies/visible upper bodies; a human should confirm the intended meaning
of `partial:false`. `distant` and `desk_occluded` attributes are absent in all 54
records. No automatic reclassification or ground-truth edits were made.

[annotation_completeness.json](../outputs/phase4_model_comparison/annotation_completeness.json)
lists every record needing attribute review. Reopen a dedicated copy:

```powershell
New-Item -ItemType Directory outputs/phase4_attribute_review
Copy-Item evaluation_baseline/labels.coco.json outputs/phase4_attribute_review/labels.coco.json
.\.venv\Scripts\python.exe -m src.annotate_persons --input sample_images --labels outputs/phase4_attribute_review/labels.coco.json
```

The existing GUI edits seated/partial/uncertain flags; it does not provide distant
or desk-occluded controls. Those additional categories require a human-authored
sidecar/schema extension before category-specific metrics. Preserve the baseline
file; attribute changes require renewed human review.

## 10. Physical-zone occupancy: pending

There are **zero reliable physical image-zone labels** and no confirmed mapping
for this photo collection. The example calibration is illustrative, not a mounted
camera record. No occupied-zone recall, false-vacancy, false-occupancy or zone F1
is claimed. All **108** pending image-zone observations remain `UNKNOWN`.

`src.phase4_zones` initializes a separate sidecar, offers a human text review flow
for all 54 person instances and independent image-zone states, and evaluates
explicitly verified physical labels against separately verified prediction mapping.
It never uses image quadrants or example polygons. A person assignment never
implies other zones are vacant. UNKNOWN ground-truth pairs are excluded; UNKNOWN
predictions have explicit coverage counts, not false vacancy/true-negative status.
Binary metrics are conditional on known predictions; occupied-zone recall
including unresolved predictions additionally exposes availability loss.

Follow [the zone checklist](phase4_zone_labeling_checklist.md). Human text fields
are provenance requirements, not automatic proof of physical validity.

## 11. Visual and false-positive/negative analysis

`annotated/<model>/<threshold>/` contains ground-truth/prediction overlays for
all six configurations at their best F1 threshold and a shared 0.40 view when
different. `side_by_side/` contains 27 selected SSD/YOLO comparisons. Cyan is
matched GT, red is FN GT, green is TP prediction and orange is FP prediction.
Each panel names the model/input size/cutoff and each prediction has its score.
JSON retains the exact numbers; displayed scores are rounded for readability.

![Nearby match, far miss, and additional YOLO FP](../outputs/phase4_model_comparison/side_by_side/IMG_20261013_133640_1.jpg.jpg)

In this example both match annotation 6 and miss annotation 5. SSD's 0.578125
box on annotation 5 has IoU **0.3765**, so it is an FP while the label remains FN.
YOLO also returns an oversized extra nearby-person box at score **0.11565**,
IoU **0.49116**, and a nonoverlapping edge box at **0.15488**. NMS does not remove
all differently sized boxes around one student.

![Far upper bodies and nonmatching predictions](../outputs/phase4_model_comparison/side_by_side/IMG_20261013_133937_1.jpg.jpg)

At best F1, **all 19 SSD FP overlap a human box but fail IoU 0.50**. For YOLO,
**four FP overlap labels below 0.50 and four have no label overlap**. None of
these selected FP meet the matching IoU as a duplicate after matching. These
geometric facts distinguish localization errors from unrelated predictions;
they do not justify relabeling or calling every FP a fixture hallucination.
[error_analysis.json](../outputs/phase4_model_comparison/analysis/error_analysis.json)
preserves each FP box, confidence, maximum GT overlap and nearest label ID.

## 12. Deployment feasibility and recommendation

[Deployment feasibility](phase4_deployment_feasibility.md) records exact export
sizes, checksums, ARMv7 wheel/native-library evidence and reproduction commands.
Desktop ONNX/NCNN equivalence does not fix weak recognition. Four-pass SSD overlap
is the strongest detection diagnostic here; its four invocations cannot be
assumed affordable on a Pi Zero 2 W. YOLO 416 is one pass per frame, but also
cannot be assumed to meet the deadline or memory budget.

**Do not promote YOLOv5n.** Preserve SSD production settings as the reproducible
baseline, while recognizing that the baseline is not classroom-ready. No tested
configuration qualifies for appliance control. Before further deployment effort,
review visible-extent/partial-label policy and collect a physically understood,
fixed-view evaluation set with varied students, lighting and empty scenes.

If an alternative must be selected for an actual Pi **feasibility-only** test,
use the exported **YOLOv5n 416 NCNN FP32** package: it has the better measured
YOLO recall/F1 and verified desktop conversion. Compare with the existing SSD
single-pass baseline using saved inputs first. This is a runtime candidate, not
an accuracy winner. Do not transfer PyTorch or converter dependencies to the Pi.

## 13. Reproduction and validation evidence

From the repository root; use new output directories to preserve evidence:

```powershell
.\scripts\setup_windows_yolov5.ps1
.\.venv-yolov5\Scripts\python.exe -m src.phase4_comparison --output outputs/phase4_repeat
.\.venv-yolov5\Scripts\python.exe scripts/export_phase4_yolov5.py --output outputs/phase4_repeat/exports
.\.venv-yolov5\Scripts\python.exe scripts/analyze_phase4.py --comparison outputs/phase4_repeat --output outputs/phase4_repeat/analysis
.\.venv\Scripts\python.exe scripts/validate_phase4.py --output outputs/phase4_validation_repeat
```

Validation uses the canonical checked-in photo evidence directory for cached-output
and export integration tests; keep `outputs/phase4_model_comparison/` available.
Those local outputs and downloaded weights are Git-ignored; regenerate the
comparison/exports after setup if absent. Setup's smoke test does not depend on
the saved comparison. The real suites can also be run directly:

```powershell
.\.venv\Scripts\python.exe -m pytest
.\.venv\Scripts\python.exe -m ruff check .
.\.venv\Scripts\python.exe -m ruff format --check .
.\.venv\Scripts\python.exe scripts/check_environment.py --static
.\.venv-inference\Scripts\python.exe -m pytest tests/integration/test_phase3_real.py tests/integration/test_windows_inference.py --run-real-inference
.\.venv-yolov5\Scripts\python.exe -m pytest tests/integration/test_phase4_real.py tests/integration/test_phase4_export_real.py --run-real-inference
```

Final software checks: **253 passed, nine deliberately skipped** in `.venv`;
existing genuine SSD tests **3 passed**, two protobuf/UPB deprecation warnings;
genuine YOLO/cached-output/export suite **6 passed**, 19 warnings. The 19 are
Matplotlib/Pyparsing deprecations and official `torch.load(weights_only=False)`
future warnings. No model/mock substitution is used in real inference tests.
The adapter hash-checks the trusted official pickle before loading. Exports also
emit expected tracing warnings for fixed shapes; no dynamic-input guarantee is made.

Ruff, format, static validation, PowerShell syntax and experimental `pip check`
passed. The 29 added unit cases cover parsing, class selection, coordinates,
letterbox inversion, thresholds, NMS, serialization, evaluator/inventory contracts,
missing/corrupt weights, zone semantics and offline isolation. All original
224 software tests remain passing. Separate environments collectively exercise
all **262** tests; TensorFlow is not installed into the YOLO environment.

The complete `setup_windows_yolov5.ps1` was subsequently executed successfully
against the pinned environment: hash verification and its real-image smoke suite
passed (**three passed, one cached-output test deselected, 18 warnings**).
See `outputs/phase4_inspection/setup_validation.log`. This repeats three of the
real tests above rather than adding three unique test cases.

Intermediate failures were retained: setup-before-install failure under
`outputs/phase4_model_comparison_setup_failed_01/`; original plotting exception
and recovery logs under `outputs/phase4_inspection/`; the original unfinished
summary as `summary.pre_finalize.json`; the initial NCNN native failure in
`exports_native_failed_01/`; and the initial one-line lint failure in
`validation_failed_lint_01/`. Plotting now handles undefined precision, NCNN uses
owned native input memory in an isolated process, and final checks pass.

Remaining blockers are recognition coverage, partial/distant/desk attribute
review, physical labels/calibration, target preprocessing equivalence, native
Bookworm 32-bit allocation and actual Pi/end-to-end resource/deadline measurements.
Windows software validation is not camera, latency or hardware validation.
