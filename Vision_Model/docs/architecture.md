# Architecture and behavior

## Data flow

```text
Pi Camera (front ceiling, looking toward classroom back)
    -> Picamera2/libcamera (640x480 RGB, two buffers, queue=False)
    -> stretch resize to model size
    -> CPU tflite-runtime SSD MobileNetV2
    -> person class filter + confidence threshold
    -> full-frame seat-region assignment (or UNKNOWN)
    -> four physical appliance owners
    -> independent temporal occupancy state machines
    -> MQTT broker on LAN
         -> ESP32 A: assigned zones / existing actuator logic
         -> ESP32 B: assigned zones / existing actuator logic
         -> optional ESP32 C: assigned zones / existing actuator logic
```

One capture and inference cycle runs at a time; camera buffers are bounded and no
application frame queue accumulates. Network I/O runs in Paho's background thread.
Live camera frames are never written to disk. Live operation has no UI,
identification, tracker or training. Calibration uses a separate offline editor.
The CPU interpreter disables default delegates and uses two configurable threads.
These are initial configuration choices, not measured performance results.

## Offline Windows path

`infer-images` reads `ImageFolder` sources using Pillow, corrects EXIF orientation
and converts to RGB, then uses the same `SSDAdapter` with native Windows
TensorFlow CPU. `inference_runtime.py` selects a real interpreter explicitly;
live Pi `run` keeps its tflite-runtime default. There is no inference-backend
fallback and no change to the reviewed model, input encoding or person threshold.
Allocated tensor dimensions are inspected and checked before preprocessing.

The offline runner writes diagnostic annotations and CSV/JSON predictions with
pixel and normalized coordinates. It does not call occupancy tracking, open a
camera or instantiate an MQTT publisher. Legacy photograph overlays are labelled
UNCALIBRATED. Version-2 overlays require their exact hash-bound reference image
and show their draft/confirmed status. Corrupt files are recorded and
skipped; native allocation/inference or output failures stop the batch with a
failure record. See [Windows evidence](windows_inference_validation.md).

## Module responsibilities

`config.py` rejects unknown settings, invalid ranges and ambiguous output mapping.
Paths resolve relative to the config file. `camera.py` lazily imports the Bookworm
camera stack only during live startup, uses libcamera's BGR888 format to obtain RGB
byte arrays, and bounds capture waits. The image transform must remain fixed after
calibration. [Picamera2's format table](https://github.com/raspberrypi/picamera2/blob/main/picamera2/encoders/encoder.py)
maps BGR888 to RGB bytes; the format name must not trigger an extra channel swap.

`detector.py` verifies the model's SHA256 and person label before creating the
runtime. Its adapter checks input metadata and explicitly configured output
positions, validates allocated output shapes, quantizes according to the configured
encoding, and returns normalized person boxes. Quantized outputs are dequantized
using their own per-tensor parameters. Unsupported layouts fail clearly.
See [model details](../models/README.md) for the actual baseline evidence.

`zones.py` retains the legacy reader and dispatches version-2 files to
`calibration.py`. The latter separates physical floor zones from image seat
regions, landmarks and exclusions. NumPy homography math and preview/editor
modules remain independent of detection/crops. `occupancy.py` maintains an independent state for
each one. `mqtt_client.py` handles the payload contract and network lifecycle.
`main.py` wires those pieces together and catches live failures.

## Physical quadrants and perspective

Left and right mean an observer at the **front looking toward the back**.
`front_left`, `front_right`, `back_left`, and `back_right` are stable IDs used by
the ESP32s. Version-2 documents use separate normalized coordinate systems:
image x/y has a top-left origin; physical floor x is left-to-right and depth y is
front-to-back. Equal image sections are not physical floor areas. All supplied
example documents remain `calibrated:false`; the old image trapezoids are legacy
preview/test data and cannot be commissioned by flipping their boolean.

The [physical calibration editor](classroom_zone_calibration.md) binds geometry
to an oriented reference hash, dimensions, camera/pose IDs and flips. Seat mode
uses manually drawn seat/bench anchor regions mapped to the four appliance
owners. The configurable initial anchor is `[0.5,0.25]` within the observed box.
It is an upper-body heuristic requiring on-site checks, not a floor point.
Exclusions, missing/overlapping regions and boundary margins produce UNKNOWN;
there is no nearest-region fallback or edge priority in this mode.

Optional ground homography requires four or more verified floor correspondences,
checks degeneracy/reprojection, and rejects extrapolation outside the reference
hull. Ground assignment needs an explicit floor-contact point and uncertainty;
it never uses a seated box bottom. The current detector supplies boxes only, so
ground-plane mode returns UNKNOWN for persons until an independent contact source
exists. No depth or foot estimator was added.

Live mode requires version-2 manual mounted-reference confirmation, a current
geometry digest and matching camera dimensions/flips. The editor's save, backup,
undo and preview never open MQTT or appliances. If any person cannot be located
reliably, application wiring invalidates all four occupancy states and clears
counts/last observation. Unknown locations do not become valid zeros. Physical
camera movement and seating changes still require manual revalidation.

## Occupancy state machine

| Condition | Behavior |
| --- | --- |
| Startup / explicit fault | All quadrants `unknown`, count null |
| Positive person counts | Candidate occupied; two hits spanning at least 0.5 seconds establish `occupied` |
| Valid zero counts | Candidate vacant; three misses spanning at least 10 seconds establish `vacant` |
| Candidate changes | Restart that quadrant's sample counter and timer |
| Observation gap over 4 seconds | Reset all quadrants to `unknown`; recovery starts confirmation again |

Initial empty observations must also complete the vacancy confirmation. Timing
uses a monotonic clock. Misses mean **successful inference with zero assigned
persons in a reliable version-2 observation**; unlocatable persons invalidate
the observation, and camera/inference exceptions never count as misses. The latest
`person_count` is an observation, so it can be zero while the debounced state
remains occupied. A still-unknown quadrant can already have a positive count.

Capture timestamps conservatively use acquisition-start monotonic time. Inference
results older than `stale_seconds` are rejected; long gaps cannot confirm vacancy.
An image is released after its cycle; no backlog can later act as fresh evidence.

## Delivery and fault behavior

The Pi publishes one full four-zone snapshot on state/count change, reconnection,
or the two-second heartbeat. Telemetry uses QoS 0 and is **not retained**. There is
no disconnected telemetry queue, and only one locally unsent telemetry packet is
allowed. This prevents an offline backlog from replaying many obsolete transitions.
Heartbeats repair lost updates. This choice does not guarantee delivery; loss
handling and the five-second target must be tested on the actual Wi-Fi network.

Availability uses a retained QoS 1 online/offline record with a boot ID and an
offline Last Will. It expresses process connectivity, not sensor validity. Every
state payload has an absolute expiry derived from both MQTT expiry and remaining
observation freshness. Consumers need synchronized UTC clocks and a local
monotonic receive watchdog. Retained online status alone never makes a state fresh.

A capture timeout, bad model output, stale inference, or unexpected exception
invalidates all quadrants, attempts an unknown snapshot, publishes offline on a
graceful close, and exits nonzero for systemd restart. A native runtime hang may
block the application; controller expiry still invalidates the last state even if
MQTT pings continue. Last Will delivery can lag a network failure, so expiry is
mandatory. The systemd stop timeout bounds shutdown of a hung process when stopped.

No actuator fallback is hardcoded. Existing ESP32 firmware must distinguish unknown
from vacancy and apply its agreed policy (for example hold state or keep required
lighting on) when a zone is unknown, expired, offline or disconnected.

## Five-second target

Arrival-to-action includes camera exposure/wait, inference, arrival confirmation,
publish scheduling, Wi-Fi/broker delivery and ESP32 actuation. The 0.5-second/two-hit
confirmation and 0.2-second cycle floor are initial settings. Slow inference,
occlusion, packet loss or reconnects can exceed five seconds. No CPU timing, RAM
measurement, accuracy benchmark or hardware validation was conducted during this
repository preparation. See [tomorrow's plan](tomorrow_test_plan.md).
