# Classroom occupancy vision

Modular, headless person detection for a **Raspberry Pi Zero 2 W**, **Raspberry Pi
OS Bookworm 32-bit**, and a front-ceiling Pi Camera facing the back of the room.
Four physical quadrants produce independent `unknown`, `occupied`, or `vacant`
states. An existing LAN MQTT broker distributes snapshots over Wi-Fi to 2–3 ESP32
DevKit V1 controllers. The Pi makes no direct actuator decisions.

**Status:** real Windows CPU allocation and image-folder inference have been executed
on all 27 sample images. The baseline returned one person detection in one image
at threshold 0.55; these are diagnostic predictions, with no accuracy claim.
See [Windows inference validation](docs/windows_inference_validation.md).
Camera operation, model inference on the Pi,
occupancy accuracy, memory usage, Wi-Fi delivery, and the **arrival-to-action target
of 5 seconds are unverified**. No hardware testing or model training was performed.
The included polygons are examples; live startup requires manually confirmed
version-2 geometry from the final mounted Pi Camera frame.

## Windows: software checks only

From this repository (`Classroom_Automation/Vision_Model`):

```powershell
.\scripts\setup_windows.ps1
.\.venv\Scripts\python.exe -m src.main check-config
.\.venv\Scripts\python.exe -m src.main simulate
```

Use Python 3.11 or 3.12. The setup script creates a local `.venv`, installs development
dependencies, checks model hashes, and runs the software tests and lint checks.
It does not change PowerShell execution policy. If local policy prevents running
the script, run its Python commands individually under your existing policy.
The lightweight development environment has no camera or inference runtime dependency. Simulation
prints 61 synthetic snapshots immediately, with no camera, inference, MQTT, or sleeps.

```powershell
.\.venv\Scripts\python.exe -m pytest
.\.venv\Scripts\python.exe -m ruff check .
.\.venv\Scripts\python.exe -m ruff format --check .
.\.venv\Scripts\python.exe scripts/check_environment.py --static
.\.venv\Scripts\python.exe scripts/inspect_model.py
```

## Windows: real image-folder inference

Use the separate **native Windows x86-64 / Python 3.12** CPU environment:

```powershell
.\scripts\setup_windows_inference.ps1
.\.venv-inference\Scripts\python.exe -m src.main infer-images --input sample_images --output outputs/classroom_baseline --runtime tensorflow --overlay-zones
```

The setup script installs the recorded environment from
`requirements-windows-inference-lock.txt`, including `tensorflow-cpu==2.16.2`
and its native `tensorflow-intel==2.16.2` implementation, then allocates the real
model. `requirements-windows-inference.txt` documents the direct dependencies.
The Microsoft x64 Visual C++ Redistributable is a prerequisite. No TensorFlow
package is added to Pi requirements or the lightweight `.venv`.

The command reads top-level JPG/JPEG/PNG files in deterministic filename order,
corrects EXIF orientation, converts to RGB and runs the reviewed SSD adapter.
It writes `annotated/`, `detections.csv`, `detections.json`, `summary.json`, and
`inference_metadata.json`. Coordinates include continuous pixels in the oriented
full-resolution image and normalized values; JSON also records zero-detection
images and unreadable-image errors. Existing result directories are preserved:
**choose a new/empty output directory for another run**, since the baseline folder
already contains the results from this session. The optional overlay is visibly
marked **UNCALIBRATED** and never changes the zone configuration. This command
does not use temporal occupancy, Picamera2 or MQTT.

```powershell
# Separate real-model tests; normal pytest skips these deliberately.
.\.venv-inference\Scripts\python.exe -m pytest --run-real-inference
# Actual allocation metadata only, with no image inference:
.\.venv-inference\Scripts\python.exe scripts/inspect_allocated_model.py --runtime tensorflow
```

Exit code 0 means all images processed, 2 means CLI usage error or a completed
batch with unreadable files, and 1 means a fatal setup/model/output failure.
Native allocation/inference faults stop the batch and save a failure record;
unreadable images are recorded and skipped. Detection output is **not ground truth**.

## Classroom preprocessing diagnostics (Phase 3A)

[Phase 3 detection diagnostics](docs/phase3_detection_diagnostics.md) records real
threshold sweeps and ROI/crop comparisons on all 27 images. It includes the local
human-box labeling utility, commands to repeat experiments, and cached evaluation
after human review. Start labeling with:

```powershell
.\.venv\Scripts\python.exe -m src.annotate_persons --input sample_images --labels outputs/phase3_diagnostics/ground_truth/labels.coco.json
```

The desktop annotation utility uses Windows Python's optional standard Tk support.
It is independent of the Pi runtime. All images start **unreviewed**; model outputs
never prefill labels. Precision/recall remain unavailable until human review is
complete. `src.phase3_diagnostics` offers full, ROI, left/right, and overlapping
crop modes with full-image reprojection and global NMS. Multiple crops increase
model invocations. The production Pi path remains one full-image pass at 0.55.

## Classroom preprocessing diagnostics (Phase 3A)

[Phase 3 detection diagnostics](docs/phase3_detection_diagnostics.md) records real
threshold sweeps and ROI/crop comparisons on all 27 images. It includes the local
human-box labeling utility, commands to repeat experiments, and cached evaluation
after human review. Start labeling with:

```powershell
.\.venv\Scripts\python.exe -m src.annotate_persons --input sample_images --labels outputs/phase3_diagnostics/ground_truth/labels.coco.json
```

The desktop annotation utility uses Windows Python's optional standard Tk support.
It is independent of the Pi runtime. All images start **unreviewed**; model outputs
never prefill labels. Precision/recall remain unavailable until human review is
complete. `src.phase3_diagnostics` offers full, ROI, left/right, and overlapping
crop modes with full-image reprojection and global NMS. Multiple crops increase
model invocations. The production Pi path remains one full-image pass at 0.55.

## Physical seating and appliance-zone calibration (Phase 3B)

The [offline calibration editor and mounted-camera procedure](docs/classroom_zone_calibration.md)
support floor landmarks, seating rows, seat/bench regions mapped to the four
appliance zones, configurable anchors, optional ground homography, UNKNOWN
assignments, preview, backup and undo. Open the illustration with:

```powershell
.\.venv\Scripts\python.exe -m src.calibrate_zones edit --image sample_images/IMG_20261013_133640.jpg --calibration config/calibration.example.yaml
```

The example remains `calibrated:false`; supplied photos cannot be confirmed as
mounted references. The tool never starts camera capture, inference, MQTT or
appliance control. Final calibration must use the real mounted camera's exact
video frame. Live mode rejects legacy example polygons even if their boolean is
changed, and unresolved version-2 person locations preserve UNKNOWN occupancy.

## Pi deployment preparation

Copy the repository to the Pi, then follow
[Raspberry Pi deployment](docs/raspberry_pi_deployment.md). Setup uses Bookworm's
OS Picamera2/libcamera and image libraries, plus `tflite-runtime==2.14.0` and
`paho-mqtt==2.1.0`. It avoids full TensorFlow, OpenCV, PyTorch, a GUI, and accelerators.

```bash
bash scripts/setup_pi.sh
.venv/bin/python -m src.main check-config
# Tomorrow, after physical calibration, MQTT configuration and commissioning:
.venv/bin/python -m src.main run
```

`setup_pi.sh` installs packages but never starts the application or a service.
`config/config.yaml` defines camera settings, explicit model I/O mapping,
debounce timing, broker address, topics, authentication environment names, and TLS.
Paths resolve relative to the YAML file, so a local configuration can be passed
with `--config config/config.local.yaml` to any CLI command.

## Model baseline

The included [Coral CPU SSD MobileNetV2 COCO17 quantized model](https://coral.ai/models/object-detection/)
has INT8 internal tensors, UINT8 input `[1,300,300,3]`, and float postprocessed
outputs. Person is output class 0. This is the CPU file, without Edge TPU operators.
The official MediaPipe catalog's purported INT8 SSD link pointed to a float16
artifact when checked; it was not used. See [model provenance and adapter
contract](models/README.md), the commit-pinned `models/manifest.json`, and the
reproducible `models/inspection.json`. No tensor layout is inferred from filenames.

## Repository map

| Path | Purpose |
| --- | --- |
| `src/main.py` | `check-config`, `simulate`, offline `infer-images`, and live `run` |
| `src/camera.py` | Bounded headless Picamera2 capture, RGB arrays, no cached frames |
| `src/detector.py` | Hash-checked, configurable SSD interpreter adapter |
| `src/inference_runtime.py` | Lazy TensorFlow CPU / Pi tflite-runtime selection |
| `src/images.py`, `src/image_inference.py` | Disk-image source, annotations and prediction reports |
| `src/zones.py` | Legacy polygon reader and version-2 calibration dispatch |
| `src/calibration.py`, `src/calibration_geometry.py` | Physical floor/seat geometry, homography, conservative UNKNOWN assignment |
| `src/calibrate_zones.py`, `src/calibration_preview.py` | Offline calibration editor, versioned files and linked image/floor previews |
| `src/occupancy.py` | Independent arrival/vacancy debounce and stale reset |
| `src/mqtt_client.py` | JSON snapshots, reconnects, freshness leases and availability |
| `src/config.py` | Safe YAML loading, typed settings and validation |
| `config/` | Configuration and illustrative perspective polygons |
| `tests/` | Synthetic tensor, geometry, debounce, config and MQTT unit tests |
| `scripts/` | Setup, static checks, model restore/inspection, systemd template |
| `docs/` | Architecture, deployment, controller contract and tomorrow's test plan |

Read [architecture](docs/architecture.md), [ESP32 integration](docs/esp32_integration.md),
and [tomorrow's test plan](docs/tomorrow_test_plan.md) before commissioning.
The [validation record](docs/validation.md) distinguishes completed software checks
from the outstanding Pi and classroom tests.

## Packaging

```powershell
.\.venv\Scripts\python.exe -m build
```

The source distribution includes configuration, model, scripts, docs and tests.
The wheel installs application code and the `classroom-vision` command. Deploy the
repository/source distribution on the Pi; if installing only a wheel, also deploy
the `config/` and `models/` directories together and supply an absolute `--config`
path. Pi hardware packages and `requirements-pi.txt` remain platform prerequisites.
No installer starts a camera or connects to MQTT.

Live camera frames stay in RAM and are not stored or transmitted. Offline image
inference saves annotated copies and prediction reports locally under the chosen
output directory. Counts are model observations, not a guaranteed census. No
repository commit or remote publication is performed automatically.
