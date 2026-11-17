# Classroom Vision Pi 5 DRY_RUN deployment

Target: Debian 13 Trixie / Raspberry Pi OS 64-bit, ARM64 (`aarch64`), CPython
3.13. This package keeps the OS-provided NumPy 2.2.x, OpenCV, and Picamera2 in
the shared-site-packages venv. It does not install pip OpenCV wheels, which would
shadow the working system OpenCV and can break the Desktop preview.

The core wheels are pinned to PyTorch 2.8.0 and torchvision 0.23.0. PyPI
publishes CPython 3.13 manylinux ARM64 wheels for both. Ultralytics 8.3.223
supports this pair. The installer uses `--only-binary=:all:` so unsupported
dependencies fail clearly rather than compiling on the Pi. [PyTorch ARM64 wheel](https://pypi.org/project/torch/2.8.0/)
and [torchvision ARM64 wheel](https://pypi.org/project/torchvision/0.23.0/).

This archive is a Raspberry Pi 5, 64-bit candidate using the existing trained
YOLOv8n classroom model and the existing six-zone runtime and preview. Default
inference settings are kept in `scripts/run_classroom_vision.py`: 640x480 camera,
25 FPS capture target, 640 inference size, confidence 0.28, NMS IoU 0.45, tracker
IoU 0.18, six-zone split 0.48, columns 0.34/0.66, inverted zones, and 180-degree
camera orientation. The six-zone settings are also summarized in
`config/six_zone_runtime.json`.

The default launch uses the `pi-vision` MQTT account and is locked to DRY_RUN.
Appliance simulation packets are sent only under
`classpulse/reb_room_301/controllers/<board>/dry_run/command`; this process
rejects HTTP attempts to switch into LIVE and does not publish appliance
commands under the physical `.../command` or `ruet/...` actuation topics.
The broker ACL for `pi-vision` must grant only app state/results writes, app
request reads, controller status/ack reads, controller hello and dry-run
command writes, diagnostic round-trip access, and read-only RUET status topics.
The provisioning script now emits those narrow rules and backs up an existing
ACL file before replacing it. It grants no writes under `ruet/` and no write to
`classpulse/.../controllers/+/command`; Mosquitto's default deny handles those
topics. The currently running broker ACL could not be changed or verified from
the build workstation because `10.247.68.155:1883` did not respond. Confirm the
effective ACL on the broker host before launching the Pi runtime. Do not treat
the process lock as a broker-side credential restriction.

## Install

On a fresh Raspberry Pi OS 64-bit Desktop install, connect the camera and run:

```bash
cd ~/Classroom_Vision_Pi5_Deployment
chmod +x scripts/install_pi5.sh scripts/run_dry_run.sh
./scripts/install_pi5.sh
cp config/mqtt.env.example config/mqtt.env
nano config/mqtt.env
chmod 600 config/mqtt.env
```

Set the broker host to `10.247.68.155`, username to `pi-vision`, and enter the
password privately. Do not put the password in shell commands or screenshots.
Picamera2/OpenCV come from Raspberry Pi OS apt packages. The installer builds a
venv with `--system-site-packages`. PyTorch, torchvision, Ultralytics, Paho, and
their support libraries are installed from binary wheels. Ultralytics is
installed without its dependency resolver, then its runtime support libraries
are installed from `requirements-pi5-support.txt`; OpenCV is intentionally
provided by apt. It does not open the camera or connect to MQTT. After
installation, `check_pi5_environment.py` checks versions and that NumPy/OpenCV/
Picamera2 resolve outside the venv. `smoke_test_pi5_inference.py` loads the
packaged weights and runs a zero-filled synthetic frame on CPU, including a
NumPy-to-PyTorch tensor round trip; it does not open the camera or contact MQTT.

If wheel installation fails, the installer leaves apt packages and the venv in
place and prints retry steps. Confirm internet access, disk space, and that
`python3` is CPython 3.13 on aarch64. Retry the printed `pip install` command.
Do not install `opencv-python` or `opencv-python-headless`. To recreate a damaged
venv deliberately, rename `.venv-pi5` to `.venv-pi5.failed` and rerun the venv
creation and install commands; this preserves its logs for inspection.

## Launch the DRY_RUN preview

From the Pi Desktop terminal:

```bash
cd ~/Classroom_Vision_Pi5_Deployment
./scripts/check_pi5_environment.py
./scripts/run_dry_run.sh
```

The existing local camera window shows the oriented feed, detections, six-zone
grid/counts, stream FPS, inference rate, and DRY_RUN mode. The local web preview
also reports MQTT connection state at `http://localhost:8080`. Press Esc in the
camera window or Ctrl+C in the terminal to stop. The preview HTTP endpoint is
for a trusted LAN only; do not forward port 8080 outside that network.

## Non-actuating broker verification

The Pi test account must have an explicit deny for physical command topics. A
broker administrator can inspect the effective ACL first. Then run the bundled
read-only connectivity check from the same Pi environment only after the admin
confirms the account's command-topic deny. The application will authenticate,
subscribe to state/feedback, and publish DRY_RUN packets, which carry
`"mode":"DRY_RUN"` on the dedicated `dry_run/command` route.

During verification, observe only:

```text
classpulse/reb_room_301/app/state
classpulse/reb_room_301/controllers/+/status
classpulse/reb_room_301/controllers/+/ack
classpulse/reb_room_301/controllers/+/dry_run/command
```

Run the round-trip probe from a Pi terminal after the private env file is set:

```bash
cd ~/Classroom_Vision_Pi5_Deployment
set -a
. config/mqtt.env
set +a
.venv-pi5/bin/python scripts/mqtt_nonactuating_probe.py
```

It authenticates as `pi-vision`, subscribes and publishes one unique token under
`classpulse/reb_room_301/diagnostics/non_actuating/`, verifies its non-retained
echo, then disconnects. It does not publish to any appliance, relay, AC, hello,
query, or controller command topic.

Do not publish to `ruet/classroom/reb_room_301/+/command`,
`ruet/classroom/reb_room_301/command/#`, or
`classpulse/reb_room_301/controllers/+/command`. The firmware must ignore the
dry-run namespace; verify that by reviewing firmware source before connecting
switchboards. Do not connect appliance loads for this prototype.

## Candidate limits

NOT TESTED in this build session: a fresh Trixie Pi installation, actual PyTorch
ARM64 wheel installation, synthetic inference execution on this Pi, Pi Camera
sensor enumeration, captured color/orientation, FPS/latency, thermals, and
actual broker ACL behavior. `config/six_zone_runtime.json` records software
geometry only; camera mounting and physical zone calibration remain unverified.
The diagnostic reference image and historical Phase 4 report are not included
because the live runtime does not use them.
