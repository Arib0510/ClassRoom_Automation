# Phase 5 Pi deployment and rollback

This package is prepared for **Pi Zero 2 W, Bookworm 32-bit, armhf/ARMv7, Python
3.11**. No Pi is connected to the development machine. All commands below are a
teammate handoff; target execution and installation acceptance remain PENDING.

## Create and transfer the package

On Windows, from the repository root:

```powershell
.\.venv\Scripts\python.exe scripts/build_phase5_package.py create --output outputs/phase5/release
```

Use a new output directory for another build. The result is
`classroom-phase5-bookworm-armhf.zip`, `package_manifest.json` and
`archive_sha256.txt`. An explicit allowlist includes SSD/model provenance,
lightweight source, safe configs, diagnostics, collection/replay tools, service
template and Phase 5 docs. It excludes all environments, images, Phase 4/YOLO
adapters, PyTorch/ONNX tools, plotting and Windows requirements. Each manifest
entry has path, size and SHA-256; it also records model/contract, dependencies,
OS/architecture, config version, OBSERVE default and unvalidated deployment status.
Checksums detect corruption, not an untrusted producer; transfer the archive and
verify its expected hash through a trusted channel.

On the Pi, choose a NEW release directory; preserve existing application/services:

```bash
sha256sum /path/to/classroom-phase5-bookworm-armhf.zip
# Compare with the trusted Windows archive_sha256.txt before extraction.
RELEASE_DIR="$PWD/classroom-phase5-release-$(date +%Y%m%d-%H%M%S)"
mkdir -m 700 "$RELEASE_DIR"
python3 -m zipfile -e /path/to/classroom-phase5-bookworm-armhf.zip "$RELEASE_DIR"
cd "$RELEASE_DIR"
/usr/bin/python3 scripts/build_phase5_package.py verify --root .
bash scripts/install_phase5.sh
```

The verifier uses only Python standard-library imports before apt installation.
The installer checks Bookworm, 32-bit ARM userland and Python 3.11; verifies
checksums; additively installs OS Python/Picamera2 dependencies; creates a NEW
`.venv-phase5 --system-site-packages`; installs only the existing Pi requirements
with `--only-binary=:all:`; and runs static/config checks. It refuses root execution
and an existing `.venv-phase5`. It never starts a service, camera or MQTT client,
and never replaces an unrelated environment or service.

## Dependency compatibility evidence

[phase5_dependency_evidence.json](../config/phase5_dependency_evidence.json) records
actual PyPI metadata and file hashes, including:

- `tflite_runtime-2.14.0-cp311-cp311-manylinux_2_34_armv7l.whl` — CPython 3.11,
  ARMv7 Linux, glibc ≥2.34. This is not an aarch64 artifact.
- `paho_mqtt-2.1.0-py3-none-any.whl` — architecture-independent Python package.

The [published runtime files](https://pypi.org/project/tflite-runtime/2.14.0/#files)
and [Paho release files](https://pypi.org/project/paho-mqtt/2.1.0/#files) support
packaging compatibility, not actual target loading. NumPy/Pillow/PyYAML and
Picamera2/libcamera come from Bookworm apt. Preserve NumPy <2 for the runtime ABI.
Do not install full TensorFlow, PyTorch, YOLO or development broker packages on Pi.
Actual apt availability, shared libraries, allocated SSD operators and camera
runtime must be verified on the target:

```bash
uname -m
cat /etc/os-release
/usr/bin/python3 -c 'import sys,struct; print(sys.version,struct.calcsize("P")*8)'
ldd --version
.venv-phase5/bin/python -m pip check
.venv-phase5/bin/python scripts/check_environment.py --pi
.venv-phase5/bin/python scripts/pi_phase5_checks.py environment --output environment-pi.json
.venv-phase5/bin/python -c 'import tflite_runtime.interpreter, picamera2, libcamera; print("imports OK")'
```

## Camera and SSD smoke tests

Ensure only one application owns the CSI camera. Review camera identity, pose,
resolution, flips and clockwise rotation in a dedicated operator configuration.
Do not change the original production files just to test Phase 5.

```bash
.venv-phase5/bin/python scripts/pi_phase5_checks.py camera-list --output cameras-pi.json
.venv-phase5/bin/python scripts/inspect_allocated_model.py --runtime tflite-runtime --output allocated-ssd-pi-01.json
.venv-phase5/bin/python -m src.phase5_data collect --count 1 --interval 1 \
  --lighting UNKNOWN --consent-reference APPROVED_CAPTURE_RECORD --output captures-pi-reference
.venv-phase5/bin/python scripts/pi_phase5_checks.py infer \
  --input captures-pi-reference/frame_00001.png --count 10 --strategy single_pass \
  --output benchmark-single-pass
```

Inspect the PNG on an authorized desktop to verify orientation/framing; capture
does not open a GUI preview on Pi. The collection tool saves lossless captured RGB,
not raw Bayer data. The inference benchmark runs a bounded real SSD worker on a
saved image without camera/MQTT/control. A 30-second default benchmark deadline
allows measurement of a slow strategy; it does not grant that deadline to the live
occupancy pipeline (three-second inference timeout/four-second freshness defaults).
Test `roi`, `left_right`, `overlap` independently with new output directories.

## Observe, calibrate, communicate and supervised tests

```bash
.venv-phase5/bin/python -m src.phase5_runtime check
.venv-phase5/bin/python -m src.phase5_runtime run --max-frames 100 --output observe-session-01
.venv-phase5/bin/python -m src.phase5_runtime summarize --input observe-session-01 --output observe-summary-01.json
```

Unconfirmed geometry produces UNKNOWN, even when predictions exist. Transfer a
captured reference to Windows and use the existing mounted-camera calibration
editor. Keep camera ID/pose/flips/dimensions identical. After real geometry review,
generate a **pending** commissioning wrapper:

```bash
.venv-phase5/bin/python -m src.phase5_runtime commissioning-template \
  --config config/operator.local.yaml --input config/mounted.local.json \
  --output config/commissioning.pending.json
```

Review/fill the wrapper using actual physical evidence; it binds exact geometry
bytes/revision and separate per-zone vacancy coverage. Set the operator config's
commissioning path only to that reviewed record. Nothing confirms illustrative
polygons automatically. See [data/calibration workflow](phase5_classroom_data_collection.md).

Copy `config/phase5.example.yaml` to a new `config/operator.local.yaml`. Supply real
broker configuration through an operator-specific copy of the existing base
config, point `base_config` to it, use a separate owned Phase 5 topic prefix, and
enable MQTT only after isolation/ACL review. Keep credentials in the environment
or a permission-restricted `config/mqtt.env`, never version control. A broker-only
non-actuating probe is:

```bash
.venv-phase5/bin/python scripts/pi_phase5_checks.py mqtt-probe \
  --config config/operator.local.yaml --output broker-probe-01.json
```

It publishes/subscribes only a unique diagnostic echo topic. It does not test an
ESP32. Actual controller integration requires the [firmware specification](phase5_mqtt_protocol.md).
DRY_RUN packets stay blocked unless reviewed firmware explicitly enforces isolation.
Populate controller/channel/ownership fields from the real installation, not examples.

For LIVE_TEST, choose only physically isolated low-voltage outputs; complete the
required evidence and matching configuration, then generate an authorization
template and have responsible reviewers complete it:

```bash
# Set the final authorization path in operator.local.yaml BEFORE generating its template.
# The template fingerprint changes if that path, mode or any other configuration changes.
.venv-phase5/bin/python -m src.phase5_runtime authorization-template \
  --config config/operator.local.yaml --output config/authorization.pending.json
# After real evidence review and binding the final authorization path/configuration:
.venv-phase5/bin/python -m src.phase5_runtime run --config config/operator.local.yaml \
  --arm-operator APPROVED_OPERATOR --arm-seconds 300 --output isolated-live-test-01
```

The operator configuration must already select LIVE_TEST and name the intended
authorization file. Complete that file without changing its configuration binding;
any later configuration change requires a new reviewed authorization. The exact interactive
session phrase and all evidence gates apply. LIVE_APPLIANCE uses the same code
with additional electrical, detection, timing and live-test acceptance gates; do
not select it merely to try the code. No example authorizes either mode.

## Observe-only systemd service

The service template is `scripts/phase5_observe.service.in`; it has bounded restarts,
whole-cgroup cleanup, MemoryMax=350M, TasksMax=64, strict filesystem protection,
private temporary storage, restrictive umask and a StateDirectory for rotated logs.
Those limits are initial guardrails, not measured Pi memory requirements. It waits
for network-online, not a guessed local broker service. Secrets are optional via
`config/mqtt.env`. The launcher rejects modes other than OBSERVE and limits stored
run directories to 32; export/archive logs explicitly when that limit is reached.

From the verified release as the intended existing application user:

```bash
APP_USER="$(id -un)" RELEASE_DIR="$(pwd)" .venv-phase5/bin/python - <<'PY'
import os,pathlib,re
user,release=os.environ['APP_USER'],os.environ['RELEASE_DIR']
assert re.fullmatch(r'[a-z_][a-z0-9_-]*',user)
assert re.fullmatch(r'/[A-Za-z0-9_./-]+',release), 'Use a release path without spaces'
text=pathlib.Path('scripts/phase5_observe.service.in').read_text()
with open('phase5-observe.generated.service','x') as f:
    f.write(text.replace('@USER@',user).replace('@RELEASE@',release))
PY
test ! -e /etc/systemd/system/classroom-phase5-observe.service
sudo install -m 644 phase5-observe.generated.service /etc/systemd/system/classroom-phase5-observe.service
sudo systemctl daemon-reload
sudo systemd-analyze verify /etc/systemd/system/classroom-phase5-observe.service
sudo systemctl start classroom-phase5-observe.service
systemctl status classroom-phase5-observe.service
journalctl -u classroom-phase5-observe.service -f
# Only after OBSERVE acceptance, if boot startup is wanted:
sudo systemctl enable classroom-phase5-observe.service
```

The installer itself does not execute these service operations. If the unit already
exists, stop and review its owner/release rather than overwriting it. Validate
`video`/`render` groups, StateDirectory ownership, camera access and sandbox rules
on the actual Pi. Service startup does not arm appliances.

Stop/rollback without deleting releases or changing unrelated services:

```bash
sudo systemctl stop classroom-phase5-observe.service
sudo systemctl disable classroom-phase5-observe.service
systemctl status classroom-phase5-observe.service
```

Preserve logs/manifests and select the prior approved release/configuration manually.
Never restore a previous live authorization automatically. Target dependency,
camera, runtime, service and hardware acceptance all remain pending until executed.
