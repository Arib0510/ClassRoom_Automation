# Phase 5 teammate hardware acceptance

**Every target/hardware item starts PENDING.** Windows unit tests, a local broker,
real desktop SSD inference and an archive do not pass these tests. Keep loads
disconnected through tests 1–10. Use existing deployment commands with new output
paths. Save reviewer, date, release/model/config hashes, firmware version and
evidence files for each result. Record failures rather than checking a box merely
because a script exists.

Initialize the record on Pi (or copy the prepared pending record):

```bash
.venv-phase5/bin/python scripts/pi_phase5_checks.py templates --output acceptance-session-01
```

## 1 — Environment

Run `scripts/pi_phase5_checks.py environment` and `scripts/check_environment.py
--pi`. Confirm Bookworm, 32-bit armhf/ARMv7 userland, Python 3.11, Zero 2 W CPU,
512 MB physical RAM, free storage, NumPy <2 and the actual TFLite/Paho/OS camera
packages. Verify archive/model hashes and import native modules. Record installed
versions and any loader failures. Metadata evidence alone is not a pass.

## 2 — Camera

Enumerate with `camera-list`, capture one approved frame with `phase5_data collect`,
and inspect orientation/resolution. Fix camera mount and record camera/pose IDs.
Collect repeated frames to verify increasing sensor timestamps, freshness,
timeouts, release/restart behavior and bounded buffering. Exercise disconnect and
reinitialization while no load is connected. Record errors and skipped-frame
estimates (estimates are not exact hardware dropped-frame counters).

## 3 — Genuine SSD inference

Use a saved camera image with a visible person and `pi_phase5_checks.py infer
--strategy single_pass`. Verify actual allocation, mapping scores=0/boxes=1/
count=2/classes=3, RGB raw UINT8 input and person ID 0 against the existing
contract. Inspect real predictions rather than assuming any returned box is a
person. Record cold/steady timing, CPU and memory; compare coordinates to reviewed
images. Allocation or a smoke prediction alone is not accuracy acceptance.

## 4 — Crop strategies

Benchmark single_pass, roi, left_right and overlap independently, with a new
directory for each. Use the same saved images and input encoding. Collect enough
samples for tail statistics. Record passes, latency, RAM and thermal behavior.
Four-pass overlap is not enabled by default; decide explicitly whether it fits
freshness/resource limits. A strategy that breaches live budgets must remain
disabled. Do not hide a failure by substituting another strategy in the same run.

## 5 — Physical calibration and detection coverage

Use the actual final mounted reference, exact orientation/dimensions, physical
front/back and appliance ownership. Review seat-region/ground-contact assumptions
with seated, standing, desk-occluded, distant and boundary persons. Do not map
bounding-box bottoms to the floor by default. Verify UNKNOWN on ambiguity.
Record version-2 geometry confirmation plus the Phase 5 wrapper, evidence date and
geometry hash. Independently review per-zone vacancy visibility/detection coverage;
unreviewed zones remain UNKNOWN when no person is detected. Obtain human zone
labels and an accuracy acceptance criterion before autonomous appliance control.

## 6 — Broker and actual ESP32 protocol

First run the unique diagnostic MQTT echo without controller actuation topics.
Then inspect actual ESP32 source/binary version, GPIO/polarity, logical channels,
topics, mode isolation, acknowledgements and watchdog policy. They are currently
unavailable. Implement/review the specified adapter before marking compatible.
Test publish, subscribe, authentication/TLS/ACLs, command IDs, acknowledgements,
nonretained commands, stale retained status, duplicate/mutated commands, replay,
out-of-order packets, expiry, reconnect and board reboot. A Python emulator result
does not pass this ESP32 test.

## 7 — Isolated low-voltage automation

Physically disconnect actual loads. Use independently reviewed LEDs/indicators or
appropriate isolated low-voltage outputs. Complete LIVE_TEST evidence and an
interactive operator grant. From each zone, demonstrate confirmed occupancy -> ON,
covered confirmed vacancy -> delayed OFF, independent appliance mappings, multiple
outputs per zone and multiple boards. Confirm UNKNOWN never becomes a guessed
vacancy. Verify manual override, timeout latch and recovery. Observe outputs
independently of acknowledgements.

## 8 — End-to-end arrival to test-output transition

Use one synchronized external recording/instrument that sees both the human
arrival boundary and indicator/output transition. Place indicators visibly in the
same recording or use an independently validated common-time acquisition method.
Do not subtract Pi and ESP32 clocks. Repeat every physical zone, varied seated/
walking entries and difficult lighting/occlusion. Record every attempted trial,
including missed/late/no-output cases. At least 20 valid trials per zone is a
useful initial plan; more are needed for stable tails, and 100 for a reported P99.

Save source evidence hashes and same-instrument timestamps in external_trials.csv.
`external-summary` reports values, missing trials and five-second misses but never
authorizes loads. Operator arrival markers and MQTT acknowledgements are supporting
diagnostics, not replacements for physical transition evidence.

## 9 — Controlled faults

With safe test outputs, exercise all fifteen required cases: Pi process death,
Pi power loss, camera disconnect, detector hang/timeout, broker stop, Wi-Fi loss,
ESP32 reconnect, ESP32 reboot, delayed acknowledgement, duplicate command, old
command replay, UNKNOWN zone, invalid calibration, stale sensor evidence and
desired/reported disagreement. Verify the independently executing board watchdog
without relying on a final Pi OFF packet. Evaluate the approved local fallback
for each appliance type; do not assume universal OFF is correct. Record every
observed output transition and recovery confirmation.

## 10 — Extended operation

Run OBSERVE and isolated LIVE_TEST sessions for a representative sustained period.
Respect the bounded supervised grant; restarting never restores it automatically.
Track total process-tree RSS, available memory, per-core-equivalent CPU utilization,
temperature, FPS, camera/detector/MQTT errors, reconnects, command failures, missed
deadlines, log rotation and disk use. Confirm capture remains latest/bounded and
shutdown releases resources. Test the observe-only systemd sandbox/restart policy
and prove an automatic restart cannot authorize appliances.

## 11 — Separate real-appliance commissioning gate

Do not run automatically. Require all prior evidence plus:

- Qualified electrical installation/inspection and responsible operator approval.
- Verified wiring, channel ownership and relay polarity/ratings.
- Correct isolation, protective devices and circuit-specific startup/fault policy.
- Confirmed manual override and independent controller watchdog.
- Verified physical-zone labels/calibration and acceptable detection coverage.
- Measured timing meeting the approved criterion, including the physical five-second target.
- Completed live-test acceptance and configuration/firmware-bound authorization.

Only then consider supervised LIVE_APPLIANCE trials with a new session grant.
No hardware or electrical approval is supplied by this repository's example files.

## Evidence returned to Windows

Return the release manifest/hash, environment output, firmware source/version/hash,
reviewed mappings and calibration, image/dataset manifests, JSONL logs, benchmark
JSON, completed acceptance record, external trial CSV and authorized recording
evidence. Use secure transfer and the classroom data policy. Keep failures and
incomplete trials. Do not send secrets, student identities or unapproved images.
