# Tomorrow's commissioning and test plan

This is a plan, not a test report. **None of the camera, inference, accuracy,
timing, network or hardware procedures below was run during repository creation.**
The target is human arrival to the relevant ESP32 action within **5 seconds**;
it remains unverified. Departure uses a separate 10-second vacancy debounce and
is not expected to meet the arrival target.

## Record the setup

Create gitignored `results/` for notes. Record date, operator, repository revision,
Pi board/OS/Python/architecture, model SHA256, configuration copies, camera module,
resolution, lens, height and orientation, lighting, seat layout, Wi-Fi signal,
broker location/version, ESP32 firmware revisions, actuator assignments and clock
synchronization. If the repository has no commit yet, record a source archive/hash.
Obtain normal permission for any volunteer observations or retained calibration
images; keep no continuous recordings by default.

## 1. Readiness gate

- Run `scripts/check_environment.py --pi` and `python -m src.main check-config`.
  Verify Bookworm 32-bit / Python 3.11 / NumPy 1.x and the pinned runtime package.
- Inspect camera connection with power off; power up and check OS camera discovery.
- Confirm the exact model allocates with the expected tensor contract on CPU. The
  first live run performs this check; record any mismatch before proceeding.
- Establish actual camera RGB order and orientation with a known color/object
  reference. Verify frame capture is fresh and follows configured flips.
- Confirm broker reachability, authentication and topic identity. Synchronize
  Pi/ESP32 UTC and measure their clock disagreement.
- Review controller fallback behavior, shared-output combination and unique client
  IDs before connecting existing actuator logic. Test LEDs/logs first where practical.

## 2. Calibrate physical quadrants

Follow the [version-2 calibration procedure](classroom_zone_calibration.md) with a
frame captured using the application's exact video configuration. Mark actual
seating rows, seat/bench anchor regions, physical appliance boundaries and
exclusions. Save reference identity and notes. Keep image coordinates separate
from physical floor coordinates. Complete manual confirmation only after on-site
review of all four owners; supplied photos remain illustrative and false.

Have a volunteer stand and sit near every zone corner, at the room center and
along shared boundaries. Check each anchor's assigned zone. Include feet hidden
by desks and truncated bodies. Boundaries, multiple region hits, excluded or
unmapped anchors must return UNKNOWN. Tune the upper-body fraction with evidence;
never project a seated box bottom as floor contact. A geometry edit does not
solve detection occlusion. Leave MQTT/appliances disabled during calibration.

## 3. Functional occupancy cases

| Case | Expected behavior / evidence to collect |
| --- | --- |
| Boot in empty room | Unknown initially, then vacant after sustained valid empty observations |
| One person in each zone separately | Only that zone confirms occupied; verify correct ESP32/output |
| Two/four zones occupied simultaneously | Independent state changes with no cross-zone activation |
| Move between zones and cross boundaries | At most one assigned zone per detected box; old zone clears after hold |
| Short detection miss / brief occlusion | Occupied state persists through configured vacancy debounce |
| Person departs | First miss begins clear timer; vacancy requires both time and sample count |
| Seated, still, partially hidden people | Record misses, false vacancy and affected viewpoints |
| Back rows / dim or uneven lighting | Record missed small people and false positives |
| Posters/chairs/empty desks | Record false person detections; no assumed pass |
| Crowded occupancy | Record saturation/occlusion; model returns at most 20 boxes |

Use manually recorded physical ground truth with zone and time. Separate wrong
person detection, wrong anchor assignment and wrong temporal/controller handling.
Calculate per-zone occupied recall, false occupied/vacant events and count error
only after collecting a defined dataset. No accuracy threshold has been promised;
agree the acceptable criteria and document sample coverage before sign-off.

## 4. Measure end-to-end arrival response

Define arrival as crossing a marked physical zone boundary. Observe the corresponding
ESP32's actual output event, using a common clock or a single external recording
of both physical events. Record separate arrival confirmation and delivery stages
where possible; MQTT receipt timestamps alone are not actuator timings.

Collect at least 10 arrivals per quadrant in representative conditions, including
idle startup, ongoing occupancy in another zone and weaker classroom Wi-Fi. Record
every trial, failures and missing actions. Report individual delays, maximum and
distribution; do not average away a trial over five seconds. Classify reconnect
trials separately while still recording their impact. A pass requires the agreed
test scope to meet <=5 seconds per applicable trial, with any exceptions explicit.

Only after baseline measurements, consider confidence/debounce/thread/resolution
changes. Change one parameter at a time, keep before/after records, and rerun
affected geometry/accuracy/latency cases. No tuning was performed today.

## 5. Failure and freshness tests

- Cover/disconnect the camera and inject a capture failure. Faults must produce
  unknown/offline or expire at the receiver, never a fabricated vacant observation.
- Pause/kill the Pi process, including an ungraceful stop. Verify local expiry
  invalidates ESP32 state even before the broker delivers the Last Will.
- Interrupt Pi Wi-Fi, ESP32 Wi-Fi and broker connectivity independently. Verify
  the receive watchdog runs without messages and reconnect starts unknown.
- Reboot Pi and each ESP32. Confirm boot ID handling, new sequence acceptance,
  stale sequence rejection and waiting for a fresh heartbeat.
- Replay old/delayed/duplicate/out-of-order messages on a controlled test topic;
  malformed JSON, missing quadrants, wrong device/schema and expired timestamps
  must not refresh receiver validity or alter outputs.
- Test retained online with no telemetry, an old retained `/state` record, missing
  time synchronization and significant NTP clock correction. No stale state may
  become newly actionable.
- Stall inference beyond the four-second observation threshold. The Pi must reject
  an old result; controller expiry must work even during a native runtime stall.
- Verify graceful shutdown, systemd failure restart, repeated-failure start limit
  and fallback while the service is stopped.

## 6. Resource and soak validation

Measure resident memory, free memory, CPU, temperature, throttling/power flags and
swap activity during normal occupancy and a multi-hour run. Watch for growth,
capture errors, disconnects and full queues. Record SD-card/log growth and ensure
there are no persisted camera frames. These observations are required before
claiming suitability for the Pi's 512 MB memory budget.

## Release decision

Do not enable unattended operation until geometry, per-zone functional behavior,
receiver fallback/expiry and the applicable five-second tests pass. Record known
limitations, unresolved failures and rollback instructions. The existing model
has limited detection capacity and can miss seated/occluded back-row pupils; if
requirements cannot be met, document that result and propose a reviewed model,
camera-placement or hardware change instead of claiming deployment success.
