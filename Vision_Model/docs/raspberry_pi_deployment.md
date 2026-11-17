# Raspberry Pi deployment

## Supported target and preparation

Use Raspberry Pi Zero 2 W (512 MB), Raspberry Pi OS **Bookworm 32-bit**, the
OS `/usr/bin/python3` **3.11**, and a supported Pi Camera on the CSI connector.
Use a stable power supply and 2.4 GHz Wi-Fi. Copy this complete repository to an
application-user-owned directory, for example
`/home/classroom/Classroom_Automation/Vision_Model`. Do not copy a Windows `.venv`.

The camera stack is **Picamera2/libcamera**; legacy `picamera`, `raspistill` and
`raspivid` are not used. Bookworm's command-line tools are named `rpicam-*`.
See [Raspberry Pi camera documentation](https://www.raspberrypi.com/documentation/computers/camera_software.html).
Camera commands below are for tomorrow, not part of today's static setup.

## Install packages without running hardware

```bash
cd /home/classroom/Classroom_Automation/Vision_Model
bash scripts/setup_pi.sh
.venv/bin/python -m src.main check-config
.venv/bin/python -m src.main simulate
.venv/bin/python scripts/check_environment.py --pi
```

The script checks Bookworm/Python/32-bit ARM first, then uses `sudo apt-get` for
OS packages and creates a local venv with `--system-site-packages`. This exposes
OS Picamera2, libcamera, NumPy, Pillow and PyYAML. Pip installs only the small
runtime/MQTT dependencies and the application. It does not enable a systemd
service, open a camera, allocate a real interpreter, or connect to the broker.

Do not use `sudo pip`, `--break-system-packages`, pip-install Picamera2 in an
isolated venv, or upgrade NumPy to 2.x. The pinned TFLite runtime is compiled
against the NumPy 1.x ABI. Keep Bookworm's NumPy (normally 1.24.2). Full TensorFlow,
MediaPipe, PyTorch, OpenCV and Edge TPU packages are unnecessary.

PyPI lists a
[`tflite-runtime 2.14.0` CPython 3.11 ARMv7l wheel](https://pypi.org/project/tflite-runtime/2.14.0/#files)
requiring glibc 2.34 or newer. Bookworm provides glibc 2.36. The setup insists on
a prebuilt wheel; availability and import compatibility on the actual Pi are
still to be checked. If pip reports no matching wheel, record Python version,
`getconf LONG_BIT`, `uname -m`, `ldd --version`, and `python -m pip debug --verbose`.
Stop and resolve that exact ABI mismatch; do not compile full TensorFlow or
silently install another runtime/model. A nonstandard 64-bit kernel with 32-bit
userland may need a reviewed wheel-tag solution or a standard target image.

## Configure network and secrets

The Windows laptop hosts Mosquitto on the trusted private hotspot at
`10.247.68.155:1883`. The broker binds only that Wi-Fi address. Its Windows
firewall rule permits TCP 1883 only from `10.247.68.0/24` on the Private Wi-Fi
interface. If the hotspot assigns a different address later, update
`CLASSROOM_MQTT_HOST`, the Flutter broker setting, and both ESP32 `secrets.h`
files, then rerun the Windows provisioning script with the new address/subnet.

Copy `config/mqtt.env.example` to `config/mqtt.env`, replace its password from
the secured Windows provisioning file, and restrict it to the Pi service user
with `chmod 600 config/mqtt.env`. The active Pi username is `pi-vision`.
For a one-session manual run, load the private environment file before starting:

```bash
set -a
. config/mqtt.env
set +a
.venv/bin/python scripts/run_classroom_vision.py --broker "$CLASSROOM_MQTT_HOST" --mode DRY_RUN
```

Use `EnvironmentFile=/home/classroom/Classroom_Automation/Vision_Model/config/mqtt.env`
for systemd. The Pi credential may publish/subscribe only within the room's
existing `ruet/classroom/reb_room_301/` and `classpulse/reb_room_301/` topic
trees. Keep passwords out of shell history, logs, and Git.

Synchronize UTC on the Pi and ESP32s (NTP/SNTP) before applying occupancy. Confirm
clock agreement and receiver expiry behavior; availability alone is insufficient.

## Tomorrow: orient and calibrate the camera

1. With power removed, inspect the ribbon and connector orientation. Mount near
   the front ceiling looking toward the back; record height, pose and lens.
2. Check OS discovery and a temporary image only when beginning hardware work:

   ```bash
   rpicam-hello --list-cameras
   mkdir -p captures
   rpicam-still --nopreview --timeout 2000 -o captures/calibration.jpg
   ```

3. Establish the final flips and framing. The diagnostic still may use a different
   aspect ratio/crop from the application; calibrate from a frame using the **same
   640×480 video configuration, transform and crop as `camera.py`**. A still from
   different framing is not a valid polygon reference. If needed, capture one
   application-config frame with a short local commissioning script tomorrow.
4. Use the [Phase 3B offline editor](classroom_zone_calibration.md) to create a new
   version-2 mounted-reference document. Mark actual seating rows, seat/bench
   upper-body anchor regions, physical appliance ownership and exclusions.
   Keep image coordinates separate from normalized physical floor coordinates.
5. Seat/stand volunteers in all four zones and at boundaries. Check the configured
   upper-body anchor and UNKNOWN handling. A hidden seated box bottom is not a
   ground point. Homography mode requires explicit verified floor contacts.
6. Export the current preview and complete the editor's explicit on-site manual
   confirmation. Set the local application config's `zones_path` to that document;
   rerun `check-config`. The legacy example file remains false and cannot be
   commissioned by changing its boolean. Calibration never starts MQTT/control.

Any camera pose, transform, crop, aspect-ratio or lens change requires calibration
review. The example polygons are not deployment geometry.

## Tomorrow: foreground commissioning

```bash
.venv/bin/python -m src.main run --config config/config.yaml
```

This command opens the camera and invokes the model. Initially every zone is
unknown. Arrival requires at least two positive observations spanning 0.5 seconds;
vacancy requires at least three empty observations spanning 10 seconds. Stop with
Ctrl+C. Faults exit nonzero and send unknown/offline when networking permits.
Receiver expiry covers cases where shutdown messages cannot be sent.

From a separate broker administration machine, observe the room topics with your
broker's normal MQTT tools. Do not pass secrets in recorded command lines. Verify
the existing controller contract in [ESP32 integration](esp32_integration.md).

## Install the service after successful commissioning

`scripts/classroom-vision.service` is a template. Replace `User`, `WorkingDirectory`,
`EnvironmentFile`, and every `ExecStart` path with the actual user/repository path.
Confirm the user belongs to the `video` and `render` groups and can access the camera.
Then, on the Pi during deployment:

```bash
sudo install -m 0644 scripts/classroom-vision.service /etc/systemd/system/classroom-vision.service
sudo systemctl daemon-reload
sudo systemctl enable --now classroom-vision.service
systemctl status classroom-vision.service
journalctl -u classroom-vision.service -f
```

The unit starts after network-online, restarts on failures, uses a read-only
filesystem view, and writes logs to journald. It does not declare startup camera
health. Repeated startup errors eventually hit the unit start limit; fix the cause,
then `sudo systemctl reset-failed classroom-vision` and restart it. A native inference
hang is detected by ESP32 state expiry; automatic hang recovery is not claimed.

Do not hardcode arbitrary memory/CPU limits before measuring actual consumption.
Tomorrow, observe service RSS, system free memory, temperature, power/throttle flags
and clock stability. Store test records under gitignored `results/`. Avoid continuous
image logging and swap-heavy workloads on the Pi.

## Troubleshooting and rollback

| Symptom | First checks |
| --- | --- |
| Camera package unavailable | `/usr/bin/python3`, venv `include-system-site-packages`, OS apt packages |
| Camera timeout / permission error | Ribbon, power, other camera users, video/render membership, OS discovery tomorrow |
| Hash or tensor contract error | Restore exact manifest artifacts; review config and `models/README.md` |
| Everything remains unknown | Zone calibration flag, camera/inference errors, stale time, detection confidence, receiver clocks |
| MQTT connects but controllers do not act | Topic prefix, boot ID, expiry, assigned zone IDs, firmware handling |
| Five-second target missed | Record each stage tomorrow; do not report a pass from config values alone |

Stop with `sudo systemctl stop classroom-vision`; disable with
`sudo systemctl disable classroom-vision`. Controllers must enter their agreed
fallback on offline/expiry. Keep a known-good repository/config copy before later
updates; restore that copy and its matching model manifest when rolling back.
