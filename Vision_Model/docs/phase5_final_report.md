# Phase 5 engineering completion report

## Result and acceptance boundary

The Pi-side integration software, decision engine, safety interlock, MQTT adapter,
reconciliation, deployment packaging, data collection and acceptance tooling are
implemented. OBSERVE is the safe default. The existing production path and SSD
model are unchanged. **Raspberry Pi execution, CSI capture, real ESP32 integration,
physical-zone correctness, watchdog behavior and electrical commissioning remain
PENDING.** The firmware is unavailable on this laptop; no real topic/GPIO/polarity
or watchdog detail was invented.

This phase builds the complete workflow now. It does not conclude that the
current SSD detector is suitable for autonomous mains control. Prior Phase 4
best-F1 SSD overlap remains 13 TP / 19 FP / 41 FN on 54 person instances. All
108 historical physical-zone observations remain UNKNOWN. YOLO is not promoted.

## Architecture and interfaces

See [architecture](phase5_architecture.md) for the module table and diagram.
Capture produces timestamped RGB frames, the SSD worker returns detections and
timings, verified mapping returns per-zone evidence, temporal tracking returns
structured states, and the appliance engine consumes those states rather than
boxes. MQTT carries validated, leased messages and feedback without vision logic.
Changing detector threshold, crop mode or physical mapping does not rewrite
transport or appliance logic.

The additive source modules are `phase5_config`, `phase5_capture`,
`phase5_workers`, `phase5_vision`, `phase5_occupancy`, `phase5_control`,
`phase5_safety`, `phase5_protocol`, `phase5_mqtt`, `phase5_runtime`,
`phase5_metrics`, `phase5_data`, `phase5_acceptance` and `phase5_simulation`.
The legacy public interfaces remain intact.

## Files created and modified

Created:

- Fourteen `src/phase5_*.py` modules listed above.
- `config/phase5.example.yaml` and `config/phase5_dependency_evidence.json`.
- `scripts/build_phase5_package.py`, `install_phase5.sh`, `launch_phase5.py`,
  `phase5_observe.service.in`, `pi_phase5_checks.py`, `phase5_test_broker.py`,
  `validate_phase5.py`.
- `requirements-windows-phase5-tests.txt` and its exact installed lock file.
- `tests/test_phase5_control.py`, `tests/test_phase5_io.py`,
  `tests/integration/test_phase5_real.py`, `tests/integration/test_phase5_broker.py`.
- Eight `docs/phase5_*.md` handoff reports.
- Machine artifacts under `outputs/phase5/`: protection inventory, metadata,
  synthetic/historical replay, pending safety/hardware records, Windows inference
  logs, real-broker logs, validation evidence, file inventory and deployment archive.

Modified during Phase 5: **`.gitignore` only**, adding `.venv-phase5-test/`.
The working tree already contained Phase 4 changes, including `MANIFEST.in`, before
Phase 5; they were not reset, committed or attributed to this phase. Original
SSD/source/config/Pi requirements, source photographs, human labels, caches and
Phase 3/4 reports were not overwritten. See
[file inventory](../outputs/phase5/file_inventory.json) and final protection evidence.
No commit or push was performed.

The final [handoff archive](../outputs/phase5/release_handoff/classroom-phase5-bookworm-armhf.zip),
[archive checksum](../outputs/phase5/release_handoff/archive_sha256.txt),
[package verification](../outputs/phase5/package_handoff/evidence.json) and
[machine-readable summary](../outputs/phase5/summary.json) identify the prepared release.

## SSD, camera and occupancy behavior

The model remains `models/ssd_mobilenet_v2_coco_quant.tflite`, SHA-256
`3438ee45f33153b1fe6c49e18bcd869ce7c94ef01c485d4eb027eaf8fc0db8ac`.
Input remains RGB raw UINT8 `[1,300,300,3]`; output positions scores=0,
boxes=1, count=2, classes=3; verified person ID 0; default threshold 0.55.
Single-pass, ROI, left/right and overlap preserve existing transforms/NMS and
require 1/1/2/4 invokes. Genuine SSD tests verify exact detection equality with
the established code. Multi-pass is explicitly opt-in and bounded by resources.

The camera wrapper supports latest bounded requests, sensor/capture timestamps,
0/90/180/270 rotation, timeouts, failures and bounded restart. Spawned workers keep
the parent responsive to native stalls. Tests use fake camera requests; genuine
Pi color order, capture and stability remain unverified.

Zone state is OCCUPIED, VACANT or UNKNOWN with reason, counts and confidence.
No-person observations require separate verified coverage before VACANT. Physical
geometry is bound to camera identity/pose/orientation/dimensions and reviewed
geometry bytes/revision. Ambiguity and unknown coverage stay UNKNOWN. Two distinct
captures across ≥0.5 seconds confirm arrival; vacancy requires ≥3 captures across
≥10 seconds, with optional extra appliance off delay. Four-second staleness and
faults invalidate state. Processing that overruns the budget before a decision
cannot authorize fresh commands. Duplicate frames cannot count as new evidence.

## MQTT, decisions, acknowledgements and safety

Automatic desired states, multiple appliances per zone, multiple boards, explicit
ownership, off delay, local overrides, rate limits, command IDs, leases, bounded
retries, output disagreement, timeout latches and reconciliation are implemented.
Pi/board sessions, challenges, boot IDs, ordering and expiry prevent stale packets
from being accepted by the specified/reference protocol. The real transport also
validates outgoing schema, mode, route, session, clock and safety authorization.

The new protocol is **proposed `classroom-control-v1`**, not verified installed
firmware. [MQTT specification](phase5_mqtt_protocol.md) gives exact topics,
schemas, firmware requirements and migration checklist. Paho communication was
tested through a real loopback broker and Python reference controller. No ESP32
firmware was compiled/flashed or claimed operational.

OBSERVE sends no commands. DRY_RUN requires recorded firmware-enforced isolation.
LIVE_TEST requires verified physical/firmware/isolated-output evidence and a
short-lived interactive operator grant. LIVE_APPLIANCE additionally requires
electrical, detection, timing, ownership and live-test acceptance records. The
observe-only service cannot restore grants or promote modes. Qualified electrical
inspection and responsible operator approval are real-world requirements; file
hashes or unit tests do not prove them. Unknown/fault states stop renewals rather
than assuming every appliance should switch OFF. Actual boards must independently
enforce the approved local watchdog/fallback policy.

## Validation evidence

Final evidence: [validation_handoff/evidence.json](../outputs/phase5/validation_handoff/evidence.json).

| Check | Result |
| --- | --- |
| Full lightweight software suite | **340 passed, 15 intentionally skipped** |
| Existing + Phase 5 genuine SSD suites | **7 passed**, 2 existing protobuf/UPB warnings |
| Preserved Phase 4 genuine YOLO/export suites | **6 passed**, 19 dependency/upstream-load warnings |
| Real loopback broker/Paho integration | **2 passed**, no ESP32 involved |
| All distinct test cases exercised across environments | **355**, zero final test failures |
| Ruff / format | Passed; 71 Python files formatted |
| Required static environment/model check | Passed |
| Python 3.11 source grammar | Passed |
| Bash installer syntax / broker environment pip check | Passed |
| Real Windows spawned pipeline | Two original images, successful exit, no actuation commands |
| Source/history protection | 94 phase-start files checked; only intended `.gitignore` change; 1,427 historical protected files unchanged |

The 15 default skips are 13 explicitly opted-in genuine model/export tests and
two explicitly opted-in broker tests. Separate environments collectively execute
them; no TensorFlow/PyTorch environment merging was performed. The new 87 unit
cases and six new integration cases supplement all existing tests. No old test
was modified to conceal a regression.

Final regression coverage includes interruption during a blocked worker IPC write
and controller reboot-history exhaustion. An interrupted worker is terminated
without waiting on a second blocked pipe write. Repeated controller restarts
exhaust a bounded budget and latch the controller out for the remainder of the
process, including MQTT reconnects, rather than accumulating boot identifiers.

Warnings are preserved in logs: two existing protobuf/UPB deprecations; 19
Matplotlib/Pyparsing/official torch.load warnings in the historical YOLO suite;
TensorFlow oneDNN informational messages in genuine Windows process execution.
Initial development dependency resolution failed because AMQTT pins PyYAML 6.0.2;
the separate test-only requirement was corrected and both logs retained. An
intermediate one-line lint failure was fixed and its validation directory retained.
No warnings or failed evidence were silently suppressed.

## Performance results and unresolved hardware facts

Genuine Windows SSD timing and worker/frame records are in
`validation_handoff/windows_pipeline/events.jsonl`. Only two photographs were used
for this pipeline smoke run. Timing is desktop evidence, not a Pi estimate; tail
percentiles are unavailable at that count. The software records cold versus
sustained setup/preprocessing/invoke/postprocessing, frame age, mapping, decisions,
MQTT enqueue/ack intervals, resources and faults. The summary tool reports mean,
median, maximum, count, invalid measurements and supported percentiles.

**No genuine Pi CPU/RSS/temperature/camera/inference value or physical activation
latency is reported.** External same-instrument human-arrival/output trials are
required for five-second acceptance. MQTT PUBACK/application ack is not physical
feedback. Synthetic fake-clock numbers are explicitly labelled and never combined
with measured Windows/Pi groups.

Pending: actual environment/native-library loading; camera orientation and capture;
model allocation/timing/RAM; selected strategy feasibility; mounted-zone labels and
coverage; actual firmware protocol, wiring/polarity/ratings/ownership; independent
watchdog and dry-run behavior; real broker/Wi-Fi/controller faults; manual override;
isolated output transitions; external end-to-end timing; sustained operation;
service sandbox on Pi; qualified electrical inspection and live authorization.

## Reproduction, deployment and teammate handoff

Windows software/replay commands:

```powershell
.\.venv\Scripts\python.exe -m src.phase5_runtime check
.\.venv\Scripts\python.exe -m src.phase5_simulation --output outputs/phase5/new_simulation.json
.\.venv\Scripts\python.exe -m src.phase5_runtime replay --input evaluation_baseline/ssd_run02_predictions.json --output outputs/phase5/new_replay
.\.venv\Scripts\python.exe scripts/validate_phase5.py --output outputs/phase5/new_validation
.\.venv\Scripts\python.exe scripts/build_phase5_package.py create --output outputs/phase5/new_release
```

For optional broker reproduction, create `.venv-phase5-test` with Python 3.12,
install `requirements-windows-phase5-tests-lock.txt`, and run
`scripts/phase5_test_broker.py test --output NEW_DIRECTORY` with that interpreter.
It always binds loopback and is never included in Pi dependencies.

Teammate sequence (commands and evidence details in
[Pi deployment](phase5_pi_deployment.md) and [hardware acceptance](phase5_hardware_acceptance.md)):

1. Verify the transferred archive checksum; extract into a new release directory.
2. Verify manifest files; run `bash scripts/install_phase5.sh` as the application user.
3. Run environment/native imports and model allocation verification; retain results.
4. Enumerate/capture camera frames with consent; inspect exact mounted orientation.
5. Run genuine saved-frame SSD and independent crop benchmarks; retain failures.
6. Collect fixed-view data and physically verify version-2 geometry/coverage.
7. Obtain actual ESP32 firmware/wiring facts; validate/adapt protocol and local policies.
8. Test a diagnostic broker echo, then firmware-enforced dry-run exchange on isolated topics.
9. Complete isolated-output evidence; run supervised LIVE_TEST with an ephemeral grant.
10. Measure external arrival-to-output timing in every zone and all controlled faults.
11. Complete sustained testing and test the OBSERVE-only service/rollback.
12. Keep LIVE_APPLIANCE blocked until separate qualified electrical/operational approval.

## Optimization priorities

Prioritize real fixed-view labels, vacancy coverage and actual firmware facts.
Measure the Pi single-pass bottlenecks before enabling multi-pass inference.
Improve seated/occluded-person coverage using reviewed data and a consistent box
policy; current weak recall is more consequential than desktop model reputation.
Tune debounce, thresholds, crops and resources only against actual recognition,
freshness and physical end-to-end evidence. Retain UNKNOWN semantics and all
controller safety gates while optimizing. No automatic model promotion occurred.
