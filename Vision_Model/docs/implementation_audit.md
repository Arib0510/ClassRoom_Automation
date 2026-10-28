# Vision_Model technical implementation audit

Historical snapshot: the later Windows image-folder implementation and real CPU
allocation/inference evidence are recorded in [Windows validation](windows_inference_validation.md).
That work resolves the Windows mode/allocation gaps below; Pi and hardware findings
remain outstanding. The original audit text is retained for traceability.

Audit date: 2026-10-25. Scope: the current `Classroom_Automation/Vision_Model`
workspace. This is an implementation and evidence audit, not classroom acceptance.
Only this report was added; application source, configuration, tests and model
artifacts were left unchanged.

The implementation provides a real model artifact, a configurable SSD adapter,
physical-zone geometry, temporal occupancy logic and an MQTT publisher. It remains
an uncommissioned application. There is **no Windows image-folder inference mode**,
**no real-model inference test among the 86 tests**, and **no recorded interpreter
allocation proving the model's runtime output shapes**. The physical polygons are
explicit placeholders. Camera operation, classroom accuracy, arrival-to-action
latency, memory suitability and ESP32 behavior remain unvalidated.

## Evidence and inspection method

Read every requested file: [README](../README.md), [validation record](validation.md),
[architecture](architecture.md), all seven application modules plus `src/__init__.py`,
both configuration files, `requirements-pi.txt`, and every file in `models/`.
Also inspected all five test modules, `src/mqtt_client.py`, `src/config.py`, setup,
model restoration and environment scripts, the service template, packaging files,
Windows requirements, and the remaining deployment/integration/test-plan documents.

Recomputed SHA-256 hashes of the three upstream artifacts and reparsed the actual
TFLite bytes using the existing FlatBuffer inspection code. Its output exactly
matches `models/inspection.json`. Also checked rank-related schema fields without
creating an interpreter. Re-ran the synthetic test suite: **86 passed**. Ran CLI
help and the static environment checker; both confirm the documented current modes
and static checks. The audit host is Windows with CPython **3.12.0**; its venv has
**no `tflite_runtime` package**.

No model was downloaded again for this audit, no real TFLite interpreter was
allocated or invoked, no sample photo was evaluated, and no camera, MQTT broker
or ESP32 was accessed. Upstream pages were checked only to corroborate model,
postprocess, camera-format and wheel information. Existing source/wheel artifacts
are present; their builds are recorded in `docs/validation.md`, not repeated here.
There is no valid Git HEAD yet, so this audit describes working-tree files rather
than an immutable repository revision.

## 1. Exact model, architecture, quantization and tensor contract

| Item | Finding |
| --- | --- |
| Local filename | `models/ssd_mobilenet_v2_coco_quant.tflite` |
| Upstream filename | `tf2_ssd_mobilenet_v2_coco17_ptq.tflite` |
| Architecture | TensorFlow 2 SSD detector with a MobileNetV2 backbone, COCO17, post-training quantization |
| Artifact role | Coral's CPU model; contains the standard CPU SSD postprocess operator |
| File size | **6,741,896 bytes** |
| TFLite schema version | **3** |
| Input layout | Batch-one NHWC, **300 high × 300 wide × 3 RGB channels** |
| Quantization | INT8 internal tensors, UINT8 external image input, FLOAT32 postprocessed outputs |
| Serialized tensor type counts | INT8 **175**, INT32 **75**, FLOAT32 **11**, UINT8 **1**; total **262** |
| Custom operators | Exactly `TFLite_Detection_PostProcess`; no Edge TPU custom operator found |
| Embedded metadata | `min_runtime_version` buffer contains `1.14.0`; this alone does not establish runtime compatibility |

The architecture identity is supported by the pinned upstream artifact and the
[Coral model catalog](https://coral.ai/models/object-detection/); shape, dtype and
quantization findings above were checked directly against local bytes. Coral
labels its catalog models as demonstration models; its published accelerator
timings are not Pi Zero CPU evidence.

### Actual serialized input

| Graph input position | Tensor index | Tensor name | Stored shape | Data type |
| --- | --- | --- | --- | --- |
| 0 | 0 | `serving_default_input:0` | `[1,300,300,3]` | UINT8 |

Per-tensor input scale is **0.007843137718737125**, with zero point **127**.
Quantized values correspond to `real = (q - 127) * scale`. These metadata values
are checked by `SSDAdapter.__init__` against configuration at real startup.

### Actual serialized outputs versus expected allocated outputs

| Graph output position | Tensor index | Meaning from postprocess wiring | Stored shape array | Stored dtype | Expected shape after allocation |
| --- | --- | --- | --- | --- | --- |
| 0 | 252 | Detection scores | `[]` | FLOAT32 | `[1,20]` |
| 1 | 250 | Detection boxes | `[]` | FLOAT32 | `[1,20,4]` |
| 2 | 253 | Valid detection count | `[]` | FLOAT32 | `[1]` |
| 3 | 251 | Detection classes | `[]` | FLOAT32 | `[1,20]` |

**The last column is derived, not measured.** In the actual file all four output
shape vectors have length zero, `HasRank` is false, and shape-signature length is
zero. The empty arrays are not evidence that inference returns scalar boxes or
zero detections. The runtime postprocess preparation determines output dimensions.
There is no saved `get_output_details()` result from an allocated real interpreter.
Therefore actual allocated output shapes cannot honestly be reported as verified.

The postprocess operator outputs tensors `[250,251,252,253]` in semantic order
boxes/classes/scores/count. The graph exposes them in order `[252,250,253,251]`.
This proves why config uses `boxes_output:1`, `classes_output:3`, `scores_output:0`,
`count_output:2`; these are graph-output positions, not tensor indices.

Expected capacity comes from local operator options `max_detections:20` and
`max_classes_per_detection:1`, interpreted using the
[TFLite 2.14 postprocess implementation](https://github.com/tensorflow/tensorflow/blob/v2.14.0/tensorflow/lite/kernels/detection_postprocess.cc).
The adapter actually accepts consistent capacity `N >= 1`, with boxes `[1,N,4]`,
classes/scores `[1,N]`, and count `[1]` or `[1,1]`; it does not hardcode N=20.
The reviewed model's capacity is expected to be 20. Exact output names are retained
in [inspection.json](../models/inspection.json); their long shared prefixes are
not used to guess semantic roles.

## 2. Source URL, checksums, download and inspection status

The exact pinned source URL in [manifest.json](../models/manifest.json) is:

```text
https://raw.githubusercontent.com/google-coral/test_data/104342d2d3480b3e66203073dac24f4e2dbb4c41/tf2_ssd_mobilenet_v2_coco17_ptq.tflite
```

Model SHA-256, independently recomputed during this audit:

```text
3438ee45f33153b1fe6c49e18bcd869ce7c94ef01c485d4eb027eaf8fc0db8ac
```

The upstream commit is `104342d2d3480b3e66203073dac24f4e2dbb4c41`. Supporting
artifact URLs use that identical revision and repository:

```text
https://raw.githubusercontent.com/google-coral/test_data/104342d2d3480b3e66203073dac24f4e2dbb4c41/coco_labels.txt
https://raw.githubusercontent.com/google-coral/test_data/104342d2d3480b3e66203073dac24f4e2dbb4c41/LICENSE
```

| Artifact | SHA-256 recomputed in audit | Result |
| --- | --- | --- |
| `coco_labels.txt` | `dc183f003fc753c4c43fae6fdf7f387559449573f13fa32e517fb7453fd380f1` | Matches manifest |
| `LICENSE.google-coral` | `f9946796a8a5bd5981565142fa42e3b0cc36aef6f80e86beaf5905b3c0fef1b5` | Matches manifest |

**Downloaded: yes, during repository preparation**, as recorded in the preparation
session and `docs/validation.md`; the full binary is present, not a placeholder
or Git LFS pointer. **Inspected: yes, statically**, both during preparation and
again in this audit. A local file/hash cannot independently reconstruct historical
network activity, but the present bytes, manifest, inspection record and preparation
record agree. **Real interpreter allocation/inference: no evidence.**

`models/README.md` explains that the MediaPipe catalog's advertised INT8 link
resolved to a float16 path during preparation, so the Coral CPU artifact was
explicitly selected. This historical catalog mismatch is recorded provenance, not
a current blocker to obtaining the included baseline. `LICENSE.google-coral`
contains the upstream Apache 2.0 license. `scripts/fetch_model.py` restores only
the reviewed artifacts, checks hashes before replacement and preserves existing
files on an invalid download. No alternate model is silently selected.

## 3. Person class index and label verification

`person_class_id` is **0**, a zero-based output class index. The label file contains
90 lines; line one, at index zero, is exactly `person`. Some later COCO slots are
`n/a`, so this is a 90-slot category map with gaps.

`src/detector.py:28`, `verify_model`, checks the model's configured SHA-256, reads
the label file with `splitlines()`, and requires
`labels[person_class_id].strip() == "person"`. Live `create_detector` calls this
before creating a runtime. The static environment checker additionally compares
the whole baseline label file to its manifest hash; that check passed in this audit.

`test_model_and_label_integrity_checked_without_runtime` checks the actual model
hash and rejects a test label file with a prepended background line when class 0
is configured. `test_static_record_explains_nonstandard_output_mapping` checks
the stored postprocess wiring. These are artifact/contract tests, not recognition
tests. The label file is external to the model; there is no independently executed
classification experiment proving the semantic association. Live `verify_model`
checks the selected label string, not the full label-file hash.

## 4. Current preprocessing

Implementation: `src/camera.py:24` and `src/detector.py:119`.

1. Picamera2 requests a **640×480** video stream, **5 fps**, `buffer_count=2`,
   `queue=False`, no preview, with both configured flips false.
2. The requested libcamera format is **BGR888**. In Picamera2/libcamera memory
   conventions this is RGB byte order, corroborated by the
   [upstream format table](https://github.com/raspberrypi/picamera2/blob/main/picamera2/encoders/encoder.py).
   No OpenCV conversion or manual red/blue swap occurs. RGB behavior on the actual
   installed camera stack has not been observed.
3. Capture returns a validated HWC UINT8 array. The detector independently requires
   a nonempty three-channel HWC UINT8 frame.
4. Pillow stretches the **entire frame** to **300×300** with **bilinear** resampling.
   This changes aspect ratio from 4:3 to 1:1. There is no crop, letterbox padding,
   tiled detection or independent inference per quadrant.
5. Current `input_encoding: raw_uint8` copies resized RGB bytes directly and adds
   the batch dimension. The actual submitted tensor is `[1,300,300,3]`, UINT8.
   **No pixel division, mean subtraction, normalization or explicit requantization
   occurs in this selected mode.** `input_mean:127.5` and `input_std:127.5` are
   inactive in this mode. Input scale/zero point are still checked at startup.

The configurable alternative `normalized_real` computes
`real=(pixel-input_mean)/input_std`. Float input receives `real`; integer input
receives `clip(rint(real/scale+zero_point))`, cast to the configured dtype.
That branch is tested with synthetic arrays and is not selected for this baseline.
The implementation supports per-tensor quantized I/O and rejects per-axis I/O.

## 5. Bounding-box decoding and detection filtering

Implementation: `src/detector.py:147`, `SSDAdapter.detect`.

The neural model performs raw SSD anchor decoding and NMS inside its
`TFLite_Detection_PostProcess` operator. Python consumes postprocessed outputs;
it does not decode raw anchors or run another NMS stage. Static options include
NMS IoU threshold **0.6000000238418579**, internal score threshold **0.0**,
`num_classes:90`, `use_regular_nms:0`, and scale parameters x/y=10, h/w=5.

The adapter:

- Calls `set_tensor` and `invoke` on its interpreter and reads four outputs using
  the explicit mapping in section 1. Real baseline outputs are FLOAT32; the
  generic integer-output branch dequantizes using each output's scale/zero point.
- Requires output arrays to retain their allocated shapes and dtypes.
- Requires valid-count output to be finite, near an integer within `1e-3`, and
  within `[0,N]`. Only the first `round(count)` detections are interpreted.
- Checks finite boxes/scores/classes; scores must be in `[0,1]`, and classes
  nonnegative and within `1e-3` of an integer.
- Keeps only rounded class **0** and scores **>=0.55**. This is a configured
  threshold, not a calibrated probability of classroom occupancy.
- Interprets a box as normalized `(ymin,xmin,ymax,xmax)`, clips its coordinates
  into `[0,1]`, and faults on a kept person box with zero or negative area.
- Returns `Detection(box, score, class_id)` objects. There is no additional
  minimum-area, aspect-ratio or partial-body filter, and no temporal identity tracker.

Malformed outputs raise a fault rather than becoming an empty observation.
Finite low-confidence person detections are discarded normally; if no kept box
is assigned to a zone, that zone gets a valid zero count. The adapter does not
upper-bound classes against the 90-line map, although it only uses person class 0.
Stretch resizing preserves normalized coordinate correspondence, so no letterbox
or crop-offset correction is required for this particular preprocessing.

## 6. Human detection and four-quadrant assignment

The pretrained MobileNetV2 network extracts learned visual features; its SSD heads
predict category scores and box offsets at multiple feature scales. Model
postprocessing turns those predictions into up to 20 scored boxes per full image.
Python selects the `person` category. There is no classroom-specific training,
student identity recognition, dedicated head detector, pose estimator, thermal
sensor or motion requirement.

`src/zones.py:107`, `ZoneMap.assign`, computes the default **bottom-center** anchor:

```text
x_anchor = (xmin + xmax) / 2
y_anchor = ymax
```

The optional `center` mode instead uses `y_anchor=(ymin+ymax)/2`. Polygon membership
uses oriented cross products with tolerance `1e-9`. Four stable IDs are required.
Polygons must have 3–12 finite normalized ordered vertices, be strictly convex,
and have no overlapping interiors; shared edges are allowed.

Each box contributes to **at most one** quadrant. Shared boundaries use the fixed
priority `front_left`, `front_right`, `back_left`, `back_right`, independent of YAML
order. An anchor outside every polygon is discarded from counts even if the box
overlaps a polygon. Bounding-box area overlap is not used. `ZoneMap.count` returns
four nonnegative integers, which feed four independent occupancy state machines.

The model itself does not know the room quadrants. Image-space polygons and the
chosen anchor approximate physical location. There is no homography, camera pose
estimate, floor-depth reconstruction or automatic calibration. A person's box
crossing several polygons never makes several quadrants occupied by itself.

## 7. Current polygons and placeholder status

Actual [config/zones.yaml](../config/zones.yaml): `calibrated:false`,
`anchor:bottom_center`. Coordinates are normalized `[x,y]`, origin at image top-left.
Left/right mean an observer at the room front facing the back. The example assumes
the classroom back appears toward the image top; that assumption is unverified.

| Physical zone ID | Current ordered polygon vertices |
| --- | --- |
| `front_left` | `[[0.10,0.48],[0.50,0.48],[0.50,0.96],[0.02,0.96]]` |
| `front_right` | `[[0.50,0.48],[0.90,0.48],[0.98,0.96],[0.50,0.96]]` |
| `back_left` | `[[0.22,0.18],[0.50,0.18],[0.50,0.48],[0.10,0.48]]` |
| `back_right` | `[[0.50,0.18],[0.78,0.18],[0.90,0.48],[0.50,0.48]]` |

**All four are illustrative placeholders.** They deliberately leave image margins
outside the monitored region and share a horizontal boundary at y=0.48 and central
vertical boundary at x=0.50. Neither those values nor the trapezoids have physical
calibration evidence. `run` refuses `calibrated:false` before creating the real
detector. `check-config` can pass with this flag false and prints `PENDING`; it
validates geometric structure, not physical correctness. Flipping the flag alone
would bypass the gate without making the geometry correct.

## 8. Partially visible, seated and occluded students

There is **no dedicated implementation for these cases**. A partial or seated
student is retained only if the general COCO model returns a person box scoring
at least 0.55. Image-edge coordinates are clipped, but the code does not infer
hidden legs, reconstruct full bodies, merge heads or recover missed students.

The bottom of a detected upper-body box can lie on a desk or torso instead of the
floor; its bottom-center can therefore select the wrong physical quadrant. A
seated person or small back-row student can be missed entirely. `center` provides
an alternative anchor, but changing it requires a corresponding physical
calibration and does not improve the detector's ability to find a person.

The 10-second vacancy delay bridges brief misses only. Continuous valid frames
with no accepted/assigned detections eventually declare vacancy even if a student
remains present. There is also **no image-quality or camera-obstruction detector**:
covering the lens can produce valid frames with zero detections and hence vacancy,
whereas a capture exception produces a fault. This distinction follows from code;
no covered-camera or seated-student experiment was performed in this audit.

The directory `sample_images/` currently contains **27 JPEGs**. No code in `src/`
or `scripts/` loads that directory for inference, and no evaluated predictions or
ground-truth accuracy results were found. Their presence is not validation evidence.

## 9. Occupancy confirmation and OFF-delay logic

Implementation: `src/occupancy.py:46`, `update`, and `snapshot`/`expire`.

| Setting / behavior | Current implementation |
| --- | --- |
| Initial state | Each quadrant `unknown`; person count and last-seen timestamp null |
| Presence criterion | Assigned person count >0 for that zone |
| Occupied confirmation | At least **2 consecutive positive observations**, spanning **>=0.5 seconds** from the first positive candidate |
| Vacant confirmation / OFF-delay | At least **3 consecutive valid zero-count observations**, spanning **>=10.0 seconds** from the first zero candidate |
| Candidate interruption | A change between positive and zero restarts that quadrant's candidate timer and sample count |
| Stability while confirming | Existing stable state remains until the new candidate satisfies both requirements |
| Startup empty room | Remains unknown until the same full vacancy confirmation is satisfied |
| Stale observation | A gap **>4.0 seconds** resets every quadrant to unknown, with counts/last-seen cleared |
| Camera/inference exception | Does not add a zero-count miss; live failure handling invalidates state and exits |

Timers use a nondecreasing monotonic clock. The OFF timer starts at the **first
valid zero observation**, not the last positive timestamp. Confirmation happens
on a subsequent valid observation, not on a timer interrupt; actual transitions
may therefore occur later than exactly 0.5 or 10 seconds. At the 4-second stale
boundary, the tracker uses `>` while the payload's remaining lease can already be
zero. Recovered observations must confirm again after invalidation.

`person_count` is the latest observation rather than a debounced count: `occupied`
can coexist with count 0 during OFF-delay, and `unknown` can coexist with a positive
count during arrival confirmation. `last_seen_age_ms` tracks the last positive
count during the current valid observation period. OFF means a published `vacant`
state; no Pi GPIO or relay is switched by this module.

## 10. MQTT message format, safety defaults and limits

Implementation: [src/mqtt_client.py](../src/mqtt_client.py) and `main.run`.
Defaults: broker **192.168.1.10:1883** (example address), client/device ID
`classroom-01-vision`, MQTT 3.1.1, clean session, keepalive **10 seconds**,
reconnect backoff **1–10 seconds**, heartbeat interval setting **2 seconds**,
expiry ceiling **8 seconds**, TLS **false**, CA path null. Credentials are optional
environment variables `CLASSROOM_MQTT_USERNAME` / `CLASSROOM_MQTT_PASSWORD`.
A password without a username is rejected. TLS certificate verification is used
when TLS is enabled. Plaintext default transport and absent credentials are not
authenticated deployment security; broker configuration is still required.

| Exact topic | QoS | Retained | Content |
| --- | --- | --- | --- |
| `classroom/classroom-01/vision/state` | 0 | No | Complete four-zone state snapshot |
| `classroom/classroom-01/vision/availability` | 1 | Yes | Device ID, boot ID, schema version, online boolean |

Representative structurally valid state payload (an illustration, not an observed
broker message):

```json
{
  "schema_version": 1,
  "device_id": "classroom-01-vision",
  "boot_id": "example-process-boot",
  "sequence": 17,
  "sent_at": "2026-10-25T06:00:00.000+00:00",
  "sent_at_unix_ms": 1792908000000,
  "expires_at_unix_ms": 1792908003600,
  "observation_age_ms": 400,
  "zones": {
    "front_left": {"state":"occupied","person_count":2,"last_seen_age_ms":400},
    "front_right": {"state":"vacant","person_count":0,"last_seen_age_ms":null},
    "back_left": {"state":"unknown","person_count":null,"last_seen_age_ms":null},
    "back_right": {"state":"occupied","person_count":1,"last_seen_age_ms":400}
  }
}
```

Availability has this shape, with `online:false` configured as the Last Will:

```json
{"schema_version":1,"device_id":"classroom-01-vision","boot_id":"example-process-boot","online":false}
```

State publishes are attempted on stable-state/count change, connection refresh or
when the heartbeat interval has elapsed. Sequence increments per attempted payload;
boot ID is a new UUID per process. Serialization rejects NaN/Infinity. The publisher
drops state while disconnected, uses nonretained QoS 0 to avoid an offline
application backlog, and permits one unsent state packet at a time. Paho is also
configured for one in-flight QoS message and a two-message QoS queue. Fake-client
tests exercise those application decisions; actual TCP/broker behavior is untested.

For a current observation, the lease in seconds is:

```text
min(8, max(0, 4 - observation_age_seconds))
```

`expires_at_unix_ms` is publication wall time plus that lease. With current
observations, usable state expires at most **four seconds** after acquisition,
not eight seconds after receipt. Missing observations force unknown and receive
the eight-second message lease; stale observations also force unknown and have a
zero remaining lease. Unknown is never a request to switch an actuator OFF.

Capture/inference faults cause an attempted unknown snapshot, graceful offline
publication and nonzero process exit. Shutdown messages are best effort. Retained
online means broker connectivity, not valid sensor data. The ESP32 must implement
UTC expiry, boot/sequence checks, a local monotonic watchdog and its agreed fallback.
Those are requirements in [esp32_integration.md](esp32_integration.md), **not
receiver firmware implemented in this repository**. QoS 0 provides no guaranteed
delivery or actuator acknowledgement. Old retained state from another publisher
requires migration cleanup; this publisher's nonretained packets do not remove it.

### Scheduling and recovery risks found by inspection

- The heartbeat check runs **inside the synchronous capture/inference loop**;
  Paho's network thread does not independently generate fresh state every two
  seconds. Slow or hung inference can delay all state publication.
- A cycle can finish within the four-second stale limit and still leave too
  little lease for the next publication. If current observation age is A and the
  next publication arrives P seconds later, uninterrupted validity needs
  approximately **A + P < 4 seconds** with these defaults. This is a design
  condition, not measured Pi timing, and needs checking before accepting defaults.
- There is no real inference timeout, process watchdog notification, or actuator
  acknowledgement path. The service uses `Restart=on-failure`, which cannot detect
  a living process stuck in native inference. Receiver expiry must provide fallback;
  automatic recovery from such a hang is not implemented.

## 11. Bookworm 32-bit dependencies and actual Python requirements

`requirements-pi.txt` contains exactly:

```text
tflite-runtime==2.14.0
paho-mqtt==2.1.0
```

This file alone is insufficient to set up the application. `scripts/setup_pi.sh`
also installs OS `python3-venv`, `python3-pip`, `python3-picamera2`, `python3-numpy`,
`python3-pil`, and `python3-yaml`, then creates a venv with
`--system-site-packages`. Picamera2's OS dependencies provide libcamera access.
The script explicitly requires `/usr/bin/python3` **3.11**, **32-bit** pointers,
Bookworm, and machine string `armv7l` or `armv8l`. It refuses execution as root
and uses sudo for apt operations only. It installs binary-only pip requirements,
then the editable application, restores/verifies model artifacts, and performs
package-presence checks. It never starts the service or tests a camera.

| Dependency | Intended target provision | Evidence / qualification |
| --- | --- | --- |
| Python | Bookworm OS CPython **3.11** | Required by setup and ARM runtime wheel ABI |
| NumPy | OS package, normally **1.24.2**, must stay <2 | Project constraint is `>=1.24.2,<2`; preserve TFLite 2.14's NumPy 1.x ABI |
| Pillow | OS package, normally **9.4** | Project allows `>=9.4,<12`; code needs `Image.Resampling.BILINEAR` |
| PyYAML | OS package 6.x | Project allows `>=6.0,<7` |
| Picamera2/libcamera | Raspberry Pi OS apt packages | Not pinned in requirements; actual installed API/version is unverified |
| TFLite runtime | `tflite-runtime==2.14.0` | Matching CPython 3.11 ARMv7l wheel is published; target install/import/allocation untested |
| MQTT | `paho-mqtt==2.1.0` | Uses Paho callback API version 2 |
| Inspection only | `tflite==2.18.0`, `flatbuffers==25.9.23` in Windows dev requirements | Schema parsers, not inference engines; optional and absent from Pi runtime requirements |

The [PyPI 2.14.0 file list](https://pypi.org/project/tflite-runtime/2.14.0/#files)
actually contains `tflite_runtime-2.14.0-cp311-cp311-manylinux_2_34_armv7l.whl`
for CPython 3.11, ARMv7l and glibc >=2.34. This is consistent with standard
Bookworm's glibc 2.36 target, but is **compatibility evidence, not a successful Pi
installation**. The release has no Windows wheel and no CPython 3.12 wheel.
Do not reuse the current Windows Python 3.12 venv for Pi inference.

`pyproject.toml` declares Python `>=3.11,<3.13`: Python 3.11/3.12 are allowed for
the application package and Windows software development. This does not imply
3.12 supports the pinned inference runtime. The source itself uses 3.11 features
including `hashlib.file_digest` and `datetime.UTC`. No full TensorFlow, PyTorch,
OpenCV, MediaPipe or GPU/TPU runtime is a Pi dependency.

Additional limitations: setup validates the system interpreter before venv creation
but an existing venv still needs checking; unusual 64-bit-kernel/32-bit-userland
systems can fail the machine-name/tag checks. `check_environment.py --pi` checks
package presence and versions without importing the native interpreter extension
or allocating the model. Apt versions are not locked into a deployment manifest.
The wheel contains code only, so wheel-only deployment requires external config
and models plus an explicit absolute `--config` path, as README explains.

## 12. Exact entry-point commands and unsupported image-folder mode

The real CLI in `src/main.py:129` accepts exactly:

```text
python -m src.main {check-config,simulate,run} [--config PATH]
```

The installed console entry point is `classroom-vision = src.main:main` and accepts
the same commands. `python src/main.py ...` is not the documented launch form
because the module uses package-relative imports.

### Windows: supported commands

From the `Vision_Model` directory:

```powershell
.\scripts\setup_windows.ps1
.\.venv\Scripts\python.exe -m src.main --help
.\.venv\Scripts\python.exe -m src.main check-config --config config/config.yaml
.\.venv\Scripts\python.exe -m src.main simulate --config config/config.yaml
.\.venv\Scripts\python.exe scripts/inspect_model.py
```

`simulate` generates 61 artificial count snapshots with no image loading, camera,
real interpreter, broker connection or sleeps. **There is no valid Windows
image-folder command to supply.** There is no `--input`, `--image-folder`, folder
iterator, disk-image camera backend, image annotation/report pipeline, or Windows
inference backend in the current source. `sample_images/` is not consumed by any
entry point. Running `run` on Windows currently first rejects uncalibrated polygons;
if that gate were bypassed, the configured TFLite/Picamera2 dependencies are still
missing. A new offline image backend and supported Windows inference runtime must
be selected and implemented before image-folder inference can be offered.

### Raspberry Pi: supported Picamera2 commands

From the deployed repository on a Bookworm 32-bit Pi:

```bash
bash scripts/setup_pi.sh
.venv/bin/python scripts/check_environment.py --pi
.venv/bin/python -m src.main check-config --config config/config.yaml
# Only after physical calibration, broker configuration and commissioning approval:
.venv/bin/python -m src.main run --config config/config.yaml
```

`run` always uses `PiCamera`; there is no backend selection flag. With the current
unchanged `calibrated:false` configuration, the final command intentionally exits
with an error. Calibration must precede setting that flag true. The service template
uses the same module command with absolute paths, which must be edited to the
actual Pi user/repository before installation. These live commands were not run
on hardware for this audit.

## 13. What the 86 tests actually exercise

**Real TFLite inference tests: 0 of 86.** Real interpreter allocation tests: **0**.
The audit re-ran all tests successfully on Windows without an installed
`tflite_runtime`. Parameterized cases count separately in the totals below.

| Test file | Collected cases | Real components exercised | Replaced / absent components |
| --- | --- | --- | --- |
| `tests/test_detector_adapter.py` | **24** | Adapter preprocessing/filtering with NumPy/Pillow; actual binary hash; label checks; saved inspection JSON | Every adapter interpreter is `FakeInterpreter`; real kernels absent |
| `tests/test_zones.py` | **20** | Actual polygon validation, assignment, edge priority and counting | Synthetic boxes/polygons; no detected image boxes |
| `tests/test_occupancy.py` | **11** | Actual temporal state machine, sample thresholds, stale reset and clock rejection | Synthetic counts and timestamps; no camera/inference |
| `tests/test_mqtt_payload.py` | **13** | Payload serialization, lease arithmetic, publisher callback/queue decisions | `FakeClient` for transport; no broker, Wi-Fi or ESP32 |
| `tests/test_config.py` | **18** | YAML/range validation, relative paths, static CLI, simulation and calibration gate | No live pipeline; `run` test exits before creating the detector |
| **Total** | **86** | Software behavior and artifact consistency | **No real inference, camera or controller validation** |

`FakeInterpreter.allocate_tensors()` is a no-op and `invoke()` merely increments
an integer counter. Its detections and tensor metadata are predefined arrays,
generally with a **2×2** synthetic input and capacity **3**, not an allocated
300×300 baseline. Thus an assertion that fake `invoke()` ran once is not evidence
that the model executed.

Two tests that touch model evidence deserve specific distinction:

- `test_model_and_label_integrity_checked_without_runtime` reads/hashes the actual
  model and verifies labels, then exercises malformed/missing-file cases.
- `test_static_record_explains_nonstandard_output_mapping` reads the existing
  `inspection.json`, not a new interpreter result. Fresh binary-to-record comparison
  belongs to `scripts/check_environment.py --static`; that comparison also passed
  during this audit.

There are no tests for `PiCamera` capture/teardown, a successful full `main.run`
cycle, actual native operator compatibility, real broker ordering/delivery,
receiver firmware, image-folder processing or classroom ground truth.
`docs/tomorrow_test_plan.md` is a plan; it contains no completed measurement data.

## 14. Remaining blockers and required evidence before classroom deployment

The following distinguish known missing implementation/configuration from checks
that must still be carried out. No code correction has been made by this audit.

| Priority | Blocker / finding | Required resolution or evidence |
| --- | --- | --- |
| Critical | Placeholder geometry and `calibrated:false` prevent live startup | Calibrate exact video framing/pose/transforms against physical quadrants; review boundaries and seated anchors; then declare calibration complete |
| Critical | Native model/runtime contract is unexecuted | Install/import pinned ARM runtime under Python 3.11; allocate actual model, record full input/output metadata and execute a real inference smoke test |
| Critical | No actual camera evidence | Verify installed Picamera2 API, permissions, ribbon, stream startup, channel order, frame freshness, configured resolution and failure behavior |
| Critical | Existing ESP32 behavior is unknown; only protocol documentation exists | Integrate/inspect existing firmware, assign zones/outputs, implement expiry/boot/sequence/watchdog/unknown fallback, and verify actual actions |
| Critical | Broker address is an example; no real MQTT exchange | Configure reachable broker, unique IDs, credentials/ACLs and transport policy; confirm reconnect, loss and retained-message migration behavior |
| Critical | Absolute expiry depends on synchronized clocks | Establish valid Pi/ESP32 UTC and receiver monotonic deadlines; reject stale/future packets and handle clock correction |
| Critical | Sustained missed detections or obscured camera can become false vacancy | Evaluate seated/partial/back-row cases and darkness/obstruction; define acceptable fallback and add a quality/obstruction mechanism if unknown-on-obstruction is required |
| Critical | <=5-second arrival target is unverified; 4-second lease may lapse between cycles | Measure actual acquisition/inference/confirmation/delivery/actuation and lease continuity; review timing only with evidence |
| High | 512 MB CPU/memory/thermal/soak suitability is unverified | Measure RSS/free memory, native allocation, power/throttling, stability and long-running capture/network behavior |
| High | Maximum 20 full-image detections and 300×300 input can suppress coverage | Test crowded rooms and every zone; agree acceptable detection/false-vacancy criteria and assess saturation |
| High for Windows photo workflow | Requested image-folder entry point does not exist | Implement explicit offline image ingestion, a compatible inference backend, output reporting and tests before claiming that workflow works |
| High | Capture/inference loop and reconnect fault paths lack integration coverage | Add controlled software integration tests; later test native failures, broker behavior and controller expiry on hardware |
| High for unattended operation | Native inference hangs do not trigger service restart | Decide whether expiry fallback alone is sufficient or add monitored recovery; verify shutdown and restart behavior |
| Deployment configuration | systemd user, paths and groups are example values | Fill in real paths/user, confirm video/render permissions, commission foreground run, then enable service |
| Reproducibility | Working tree has no Git HEAD; OS package versions are not captured | Record a release revision/source hash plus actual OS/apt/pip/config/model versions and rollback package |

Further noncritical findings: `.gitignore` and `MANIFEST.in` contain duplicate
patterns, which are harmless but untidy. Full label-map hashing is a separate
static/setup check rather than part of every live `verify_model` call. Native
startup failures occur before the publisher is started, so they cannot reliably
send a new offline record; receivers must expire the previous state. An online
Last Will record alone is insufficient. The default data path does not preserve
images or per-frame inference/zone traces for diagnosis, and there is no built-in
annotation or calibration tool.

The tomorrow plan's covered-camera case needs careful interpretation: an opaque
lens cover is not necessarily a capture exception. The current implementation can
successfully capture and infer an apparently empty image and declare vacancy.
The claim that all such visual failures become unknown would be incorrect.

## Critical issues requiring correction before Raspberry Pi deployment

1. Replace placeholder zones with physically verified geometry; keep the live gate
   closed until calibration is real.
2. Establish Bookworm 32-bit/Python 3.11 native compatibility and record actual
   model allocation/output metadata plus a real inference result.
3. Commission Picamera2 framing, RGB order, freshness and failure behavior on the Pi.
4. Configure the actual broker and integrate ESP32 expiry, unknown fallback,
   boot/sequence handling, synchronized clocks and physical output ownership.
5. Resolve false-vacancy risk for seated/occluded students and visual camera failure;
   validate the required detection coverage and fallback policy.
6. Verify the five-second arrival target, four-second freshness lease continuity
   and 512 MB resource/stability budget before unattended use.
7. Implement Windows image-folder mode before presenting any command for that
   workflow; it is a missing feature, separate from the Picamera2 entry point.
