# Phase 3A: classroom person detection diagnostics

Date: 2026-10-25. Real offline CPU inference on the existing **27** classroom
JPEGs. This implements diagnostics and experimental preprocessing; human ground
truth is still **0/27 images reviewed**. No accuracy, precision, recall, false-positive
or false-negative counts are asserted for this dataset. No Pi performance or
hardware validation was performed.

## Findings supported by this run

1. **The 0.55 threshold is not sufficient to explain the widespread misses.**
   Full-image inference exposes only **four person-class output slots across two
   images**, even at a per-call cutoff of zero. Scores are 0.48828125–0.5703125.
   At 0.55 only one remains; at 0.10 four remain. The other **25 images have no
   returned person-class box**, so lowering the Python threshold cannot recover
   people from their current full-image outputs. Visual review of
   `IMG_20261013_133640.jpg` shows the two full-image boxes around the same nearby
   student, with the more distant student unboxed. Extra boxes are not necessarily
   extra people.
2. **The first single ROI trial provides little evidence of improvement.**
   With ROI `[0,0.35,1,1]`, it returns five boxes at 0.10, still confined to two
   images, and one at 0.55. More importantly, visual review of tilted photographs
   shows this boundary cuts through/excludes back-row students. It is unsuitable
   as a shared preset for these varied camera poses. The preserved second trial
   uses `[0,0.20,1,1]` to retain higher students; this choice follows image content,
   not maximization of prediction count.
   With the safer top edge, the single ROI produces six boxes across three images
   at 0.10 and two across two images at 0.55, a modest prediction-count change
   that does not establish improved person recall.
3. **Spatial crops expose additional seated-person candidates.** In the first
   trial, left/right and overlap modes return 17 and 42 boxes at 0.10 across 10 and
   23 images. For example, the left/right image of `IMG_20261013_133640.jpg`
   contains a 0.375 box on the distant visible upper body where the full pass has
   no person box. The overlap image contains a 0.41015625 upper-body candidate.
   This is qualitative localization evidence, not measured seated-person recall.
   Duplicates and oversized torso-plus-desk boxes remain visible.
4. **Misses remain.** `IMG_20261013_133937_1.jpg` visibly contains back-row upper
   bodies, yet the first trial returns no person boxes in any mode.
   `IMG_20261013_134007.jpg`, `IMG_20261013_134007_1.jpg`, and
   `IMG_20261013_134009.jpg` also have zero person outputs in every first-trial
   mode; their tilted framing requires particular ROI review. In
   `IMG_20261013_134008.jpg`, overlap at 0.10 boxes the left upper body but leaves
   the visible right upper body unboxed; the initial ROI excludes that upper
   region. These are visual review findings, not an exhaustive human-labelled
   false-negative inventory. Every image/mode/threshold is listed in the CSV.
   With the second ROI, **`IMG_20261013_134007.jpg`,
   `IMG_20261013_134008.jpg`, `IMG_20261013_134009.jpg`, and
   `IMG_20261013_134009_1.jpg` have no returned person box in any mode**, including
   before the score cutoff. The safer ROI retains the upper student regions, so
   the initial crop exclusion does not explain these remaining output gaps.
5. **Pi candidates require budget-aware testing.** Full-image baseline and a
   conservatively framed single ROI each require one invocation and are the first
   resource-test candidates. Left/right costs two invocations and is an optional
   experiment if human labels establish useful incremental coverage. Four tiles
   cost four invocations, so remain a diagnostic reference until labels justify
   that expense and actual Pi resource/freshness measurements permit it. No mode
   was promoted into production and the global threshold remains 0.55.
6. **Uncertain:** actual recall, precision, false positives, partial/seated
   coverage, box-policy sensitivity, optimal thresholds/ROI/NMS, crowded-room
   behavior, the final camera pose, and Pi CPU/RAM/latency suitability. More
   prediction boxes do not resolve these questions. No partial-body training or
   model architecture change was attempted.

## Actual threshold comparisons

Counts below are **retained prediction boxes**, not actual persons. Full/ROI have
model NMS only; left/right and overlap also have the specified global NMS.

First trial, ROI `[0,0.35,1,1]`, preserved to expose ROI exclusion risk:

| Mode | 0.10 | 0.20 | 0.30 | 0.40 | 0.50 | 0.55 |
| --- | --- | --- | --- | --- | --- | --- |
| Full | 4 | 4 | 4 | 4 | 3 | 1 |
| ROI | 5 | 5 | 5 | 5 | 3 | 1 |
| Left/right | 17 | 17 | 17 | 14 | 5 | 3 |
| Overlap 2x2 | 42 | 42 | 41 | 25 | 11 | 7 |

Second trial, ROI `[0,0.20,1,1]`, chosen to preserve high students in tilted photos:

| Mode | 0.10 | 0.20 | 0.30 | 0.40 | 0.50 | 0.55 |
| --- | --- | --- | --- | --- | --- | --- |
| Full | 4 | 4 | 4 | 4 | 3 | 1 |
| ROI | 6 | 6 | 6 | 6 | 4 | 2 |
| Left/right | 7 | 7 | 7 | 5 | 3 | 3 |
| Overlap 2x2 | 56 | 56 | 53 | 32 | 13 | 6 |

At 0.10 the second trial has predictions in 2/3/7/23 images for
full/ROI/left-right/overlap respectively; at 0.55 those counts are 1/2/3/5.
Preserving a larger ROI decreases left/right candidates while increasing tile
candidates, illustrating sensitivity to scale, context and aspect distortion.
The raw model postprocess returned no extra full-image person slots below 0.40.
Scores for all classes still compete for the 20 output slots; lowering a Python
threshold does not rerun that competition. The evidence supports investigating
scale/context and framing; it does not isolate occlusion, training distribution,
internal anchor behavior or quantization as a proven cause.

See [first-trial summary](../outputs/phase3_diagnostics/run_01/summary.json),
[second-trial summary](../outputs/phase3_diagnostics/run_02/summary.json), and
[second-trial per-image results](../outputs/phase3_diagnostics/run_02/per_image_results.csv).
Native crop PNGs allow direct review of how much upper-body detail survives at
300x300. The largest reported model score is not an automatic configuration choice.

## Model, source data and pipeline contract

Read `AGENTS.md`, the [implementation audit](implementation_audit.md),
[Windows validation](windows_inference_validation.md), `src/detector.py`,
`src/zones.py`, and the real offline/live pipelines before implementation.
The reviewed model and external label map are unchanged:

```text
models/ssd_mobilenet_v2_coco_quant.tflite
SHA-256: 3438ee45f33153b1fe6c49e18bcd869ce7c94ef01c485d4eb027eaf8fc0db8ac
```

`create_detector` checks those bytes and person label before allocating. Runtime:
existing Windows CPython 3.12, TensorFlow CPU/Intel 2.16.2, CPU with two threads,
default delegates disabled. Allocated input is UINT8 `[1,300,300,3]`. Output roles
remain explicit: boxes=1, classes=3, scores=0, count=2; model person class=0.
Quantization checks and output validation remain in the shared adapter.
The model's allocated 20-slot SSD postprocess output is **not the raw SSD anchor
tensor**: its own NMS/top-output selection has already run across categories.
Absence of a returned person box does not prove absence of all internal person
responses. Only postprocess slots within the reported valid count are inspected.

Both trials process exactly the same sorted input inventory, with EXIF correction
and RGB conversion. Every source hash matches the previous
`outputs/classroom_baseline/detections.json` inventory. Original image bytes are
unchanged. All overlays and native crop inputs are new copies under `outputs/`.
Full-image outputs at 0.55 reproduce the previous one-box result.
Scores are model outputs, not calibrated probabilities of a human.

## Preprocessing implementation

`src/crops.py` provides reusable preprocessing independent of camera, MQTT and
physical-zone code. Experimental modes are:

| Mode | Crop definition | Invocations/image |
| --- | --- | --- |
| `full` | Whole oriented image, ignoring the ROI | 1 |
| `roi` | One normalized classroom rectangle | 1 |
| `left_right` | Two horizontal halves of that ROI | 2 |
| `overlap` | 2x2 spatial tiles inside that ROI | 4 |

ROI CLI order is **xmin ymin xmax ymax**, each finite in `[0,1]`, with strictly
positive width and height. The diagnostic default is `[0,0.20,1,1]`; override all
four edges with `--roi`. This is an illustrative photo preset, not on-site
calibration. A single rectangle cannot remove all walls/projectors while retaining
every student across different tilted camera poses. Use the previews to adjust
the boundaries for the actual fixed framing. No claim is made that these trials
completely exclude fans, projectors or walls.

Crop left/top edges are rounded down, right/bottom edges up, giving exclusive
integer pixel bounds. Each crop stretches bilinearly to the **same native
300x300** input and uses the existing reviewed raw UINT8 encoding. There is no
letterbox, extra normalization, alternate model or interpreter reinitialization
between crops. Crops run sequentially from views of one source image. A single
allocated interpreter serves a complete trial (216 successful invocations:
27 images x (1+1+2+4)). Threshold sweeps reuse those outputs, adding no invokes.

For actual integer crop bounds `(L,T,R,B)` in source size `(W,H)`, local model
coordinates `(y0,x0,y1,x1)` map to:

```text
full_y0 = (T + y0*(B-T))/H    full_x0 = (L + x0*(R-L))/W
full_y1 = (T + y1*(B-T))/H    full_x1 = (L + x1*(R-L))/W
```

Thus rounding, crop offsets and source dimensions are preserved, including odd
image sizes. Overlap is **0.20 of tile width/height**, with tile extent equal to
ROI extent divided by `(2-overlap)` on each axis; allowed overlap is `[0,0.9)`.
There are four tiles, not one crop per physical room zone.

Multi-crop outputs receive stable score-ordered, class-aware global NMS at
**IoU >=0.50** after reprojection. Winning boxes and scores remain unchanged.
Every raw returned person slot is saved with local/full coordinates and its source
crop; reports also list suppressed raw detection indices. Single full/ROI passes
retain model postprocess behavior without an additional NMS stage. NMS can leave
two different-size boxes around one person when their overlap is below 0.50;
lowering NMS IoU without labels can also merge neighboring students. No heuristic
was added to force prediction counts to resemble an assumed actual count.

The detection ROI **is not** a physical occupancy polygon. `src/zones.py`, zone
configuration, bottom-center assignment, occupancy/stale behavior, MQTT expiry and
bounded buffering are unchanged. Seated-box anchors still require physical
calibration. The live `src.main run` path retains one full-image inference at
the existing 0.55 threshold. No Pi dependencies or camera code changed.

## Human labeling and evaluation

The standalone desktop utility is `src.annotate_persons`. It displays originals
after EXIF orientation, supports drawing boxes, zooming and scrolling, navigating
all 27 images, selecting/deleting boxes and applying per-person flags. It uses
Windows Python's optional standard Tk support and Pillow, with no new Pi package.

```powershell
.\.venv\Scripts\python.exe -m src.annotate_persons --input sample_images --labels outputs/phase3_diagnostics/ground_truth/labels.coco.json
```

Enter a human reviewer name. For **each visible individual**, draw a tight box
enclosing visible person pixels, including a seated upper body or image-edge
partial person; do not extrapolate hidden limbs/full bodies. Set `partial` and
`seated` as appropriate. Mark unclear/heavily occluded possible persons `uncertain`.
Select a saved box, change checkboxes and use **Apply flags to selected** to edit
flags; delete and redraw to correct geometry. After checking all visible persons
in an image, mark it reviewed, including genuinely empty images. Edits clear that
image's review status. Changes autosave atomically; reopening preserves labels.
No model overlays or predictions are supplied to this utility.

The initialized file contains all 27 image records, hashes and oriented dimensions,
an empty annotation list, and `reviewed:false` on every image. It is a **pending
human annotation inventory**, not ground-truth evidence of an empty room.
COCO boxes use pixel `[x,y,width,height]`. Human category **1** explicitly means
person; it is distinct from verified model output class **0**. Each annotation
has boolean `uncertain`, `partial`, `seated` attributes and `iscrowd:0`. Every
reviewed image requires `reviewed_by`. Evaluation rejects mismatched image
inventories, source hashes, dimensions, categories, invalid boxes and flags.

Once all 27 images have been human reviewed, evaluate **cached predictions** into
a new directory; no interpreter is created and no inference is repeated:

```powershell
.\.venv\Scripts\python.exe -m src.phase3_diagnostics evaluate --input sample_images --predictions outputs/phase3_diagnostics/run_02/predictions.json --labels outputs/phase3_diagnostics/ground_truth/labels.coco.json --output outputs/phase3_diagnostics/evaluated_run_02
# Repeat with run_01/predictions.json and a different empty output if desired.
```

Matching uses **IoU >=0.50**, in the full oriented image, one prediction per
certain label and one certain label per prediction. Predictions are processed by
descending score, choosing the highest-IoU unmatched certain label. Remaining
predictions overlapping an uncertain label at the matching IoU are ignored for
primary metrics and reported separately. Uncertain people never contribute
primary false negatives or recall denominators. Precision is TP/(TP+FP); recall
is TP/(TP+FN); a zero denominator yields JSON null. Reports include per-image
detected/certain/uncertain totals, FP/FN IDs, and recall for partial people and
the `partial && seated` subset. Visible-extent labels can penalize oversized
full-body boxes; review those localization failures explicitly.

`label_output_review.json` searches all raw returned person boxes for each human
label at the matching IoU, separately identifying localization only below 0.10,
below 0.55, at/above 0.55, or absent from returned person boxes. This per-label
inspection is separate from one-to-one recall matching. With incomplete human
review, its `persons` field remains null. All primary accuracy fields also remain
null/blank, even if some images have labels. No actual/FP/FN counts are filled
from model predictions.

## Reproduce the two real trials

The following commands were actually run. Existing nonempty output directories
are refused, so use a new directory to repeat them. Both use the same human-label
inventory and model; the only changed experiment setting is the ROI top edge.

```powershell
.\.venv-inference\Scripts\python.exe -m src.phase3_diagnostics run --input sample_images --output outputs/phase3_diagnostics/run_01 --labels outputs/phase3_diagnostics/ground_truth/labels.coco.json --runtime tensorflow --roi 0 0.35 1 1 --overlap 0.2 --nms-iou 0.5 --matching-iou 0.5
.\.venv-inference\Scripts\python.exe -m src.phase3_diagnostics run --input sample_images --output outputs/phase3_diagnostics/run_02 --labels outputs/phase3_diagnostics/ground_truth/labels.coco.json --runtime tensorflow --roi 0 0.20 1 1 --overlap 0.2 --nms-iou 0.5 --matching-iou 0.5
```

The diagnostic cutoff override is local to each call: no production YAML threshold
is edited. Raw collection retains **every valid returned person slot**, including
any below 0.10. There is no pre-threshold assumption that a person output is true.

## Saved artifacts

All experiment evidence is under `outputs/phase3_diagnostics/` (gitignored local
artifacts); this document and source/tests are versionable. Within each run:

| Path | Contents |
| --- | --- |
| `predictions.json` | All raw returned person slots, scores, normalized/pixel coordinates, source crops, input inventory/hashes, settings, actual runtime/tensor metadata/invoke count |
| `threshold_comparisons/<mode>/threshold_<value>.json` and `.csv` | Separate reports for all six cutoffs per mode; JSON retains images with zero predictions |
| `annotated/<mode>/<threshold>/` | 648 prediction overlays per trial, visibly labelled as predictions |
| `roi_previews/<mode>/` | 108 crop-boundary previews per trial, explicitly independent of physical zones |
| `model_inputs/<mode>/` | 216 native 300x300 pre-encoding RGB PNG crop inputs per trial |
| `per_image_results.csv` | 648 image/mode/threshold rows per trial; actual/FP/FN blank until labels complete |
| `ground_truth/labels.coco.json` | Label snapshot as it stood at experiment time |
| `ground_truth/annotated/` | Human-label overlay copies, marked PENDING for unreviewed images |
| `false_negative_review/` | Pending unlabelled review copies until complete labels; then missed certain human boxes in red, uncertain in orange |
| `summary.json`, `diagnostic_summary.md` | Counts, completeness, matching semantics and unresolved limitations |
| `label_output_review.json` | Completeness-gated per-human-label inspection of returned person outputs |

The editable human label inventory is at the **parent**
`ground_truth/labels.coco.json`; run snapshots stay unchanged when labeling later.
Captured logs are `run.log`, `run_02.log`, and `real_tests.log` in the parent.
Allocation/inference faults preserve partial prediction cache plus the failure
message; evaluation refuses an incomplete cache. Corrupt inputs stop a trial
before accuracy reporting. The annotation GUI was constructed/rendered hidden
as a smoke check; interactive human labeling has not been performed.

## Software verification

Validation uses the local lightweight `.venv` and the already installed separate
Windows inference `.venv-inference`. Required pytest/lint/format/static checks and
the real-model integration suite are recorded with final counts below. New tests
exercise ROI bounds/nonfinite values, actual integer rounding and transforms,
coverage and overlaps, duplicate NMS/ties, score/crop reporting, reuse of native
allocation, unchanged default threshold, human label validation/completeness,
uncertain and partial/seated matching, IoU matching, cached evaluation without a
runtime, result preservation, and low-score-versus-absent localization review.

Executed after the code changes:

```powershell
.\.venv\Scripts\python.exe -m pytest -q -p no:cacheprovider
.\.venv\Scripts\python.exe -m ruff check .
.\.venv\Scripts\python.exe -m ruff format --check .
.\.venv\Scripts\python.exe scripts/check_environment.py --static
.\.venv-inference\Scripts\python.exe -m pytest -q --run-real-inference -p no:cacheprovider
```

Results: **158 passed, 3 deliberately skipped** in the lightweight environment;
**161 passed** with real inference enabled. Both existing real-model integration
tests passed, along with the added actual classroom crop test. Lint, formatting
and static environment/model inspection all passed. The only real-suite warnings
were the existing two protobuf/UPB deprecation notices under Python 3.12. The new
real test verifies native 300x300 operation through all four modes, matching the
previous full-image result and maintaining a single adapter invocation counter
across the baseline plus eight crop calls. These are contract checks, not accuracy
or speed tests. Both trials completed with **27/27 images, no failures, and 216
invocations each**, totaling **432** diagnostic model invocations. Artifact
inventory and original image/model hash checks are saved in
`outputs/phase3_diagnostics/validation_evidence.json`.

No cameras, MQTT connections, ESP32s, appliances, training, replacement/downloaded
weights, or inference performance benchmarks were used. These are software and
Windows offline recognition diagnostics, not camera, accuracy, latency or hardware
acceptance results.
