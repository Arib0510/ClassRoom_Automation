# Phase 5 performance instrumentation and evidence

The five-second target is **human arrival to independently confirmed physical
activation**. No Pi, ESP32 or physical output has been measured here. Windows
model execution, simulation and real loopback MQTT tests are separate evidence.
They cannot establish Pi speed or classroom readiness.

## Instrumentation implemented

JSONL records contain provenance, monotonic time, frame/session/config/model IDs,
cold-start versus sustained phase and the following measurements/counters:

| Stage | Measurement and limitation |
| --- | --- |
| Camera | Capture request duration; sensor timestamp and age; orientation; superseded-frame estimate; failures |
| Preprocessing | Actual existing SSD `prepare` duration across selected crops |
| Inference | Interpreter `invoke` duration only; number of model passes |
| Postprocessing | Remaining adapter/crop reprojection/NMS overhead; JSON/transport overhead is outside kernel time |
| Mapping | Physical mapping/visibility-check duration |
| Temporal | Candidate capture time, distinct-frame hits, transition and confirmation delay |
| Decision pipeline | Frame capture to local decision/transport enqueue; not human arrival to load activation |
| MQTT | Local enqueue/validation time; matching command-to-ack Pi monotonic interval |
| Outputs | Controller-reported logical state; physical transition explicitly unconfirmed |
| Resources | Linux parent/process-tree RSS, available memory, CPU time/utilization, thermal sensor, FPS |
| Faults | Camera/detector faults, resource/deadline events, reconnects, invalid packets and command failures |

Native inference timing uses `perf_counter`; source/control timestamps use
monotonic clocks on one device. SensorTimestamp age is computed in its documented
CLOCK_BOOTTIME domain and then translated locally. No ESP32 clock is subtracted
from Pi time. Missing `/proc`/thermal counters are null, including on Windows.
CPU utilization is process-tree CPU seconds per elapsed second ×100 and may
exceed 100 on multiple cores; it is not normalized to the whole quad-core CPU.

Rotated JSONL files are bounded by configured max bytes and backup count. Summaries
describe retained samples only. Keep/export a completed acceptance run before its
evidence rolls out of retention. A run directory is new, never reused to overwrite
historical results. The unattended launcher refuses more than 32 run directories
until an operator archives them.

## Reproduction

Pi saved-input benchmark, separate cold and sustained samples:

```bash
.venv-phase5/bin/python scripts/pi_phase5_checks.py infer \
  --input captures-pi-reference/frame_00001.png --count 100 --strategy single_pass \
  --output benchmark-pi-single-01
```

Repeat each strategy independently. The benchmark deadline can be adjusted with
`--timeout` for diagnostic measurement; this never changes the live configuration's
freshness or command authorization. Camera acquisition and control are not part
of this saved-input benchmark. For full pipeline observations:

```bash
.venv-phase5/bin/python -m src.phase5_runtime run --max-frames 1000 --output observe-benchmark-01
.venv-phase5/bin/python -m src.phase5_runtime summarize --input observe-benchmark-01 --output observe-benchmark-summary-01.json
```

Counts, mean, median, maximum, invalid/incomplete records and deadline misses are
reported. P90 requires ≥10 samples, P95 ≥20 and P99 ≥100; otherwise those values
are null. These minimum counts permit reporting, not statistical independence.
Hardware cold-start/model-worker setup is recorded separately from sustained
frame processing. Accuracy, empty-room failures and missed arrivals must also be
reviewed; a low latency among successful detections can conceal non-detections.

## Operator markers and physical timing

`Pipeline.mark_arrival` and a same-Pi local request can record an operator reaction
marker to first OCCUPIED decision. Run with `--override-file operator-request.json`,
read its current session from logs, and immediately create on that Pi:

```bash
.venv-phase5/bin/python -m src.phase5_runtime request --session SESSION_FROM_LOG \
  --operator REVIEWER --action arrival --zone front_left --output operator-request.json
```

The marker must arrive within two seconds and uses the same Pi monotonic clock.
It has human reaction/CLI delay and **does not independently measure actual
arrival**. A failed confirmation remains an incomplete trial, not a zero latency.

For genuine physical latency, record both arrival and test-output transition on
one validated external timeline. Fill the pending external_trials.csv with zone,
cold/sustained phase, clock identifier, source recording and checksum. Include
no-output trials as incomplete rather than deleting them. Then:

```bash
.venv-phase5/bin/python scripts/pi_phase5_checks.py external-summary \
  --input acceptance-session-01/external_trials.csv --output external-summary-01.json
```

The parser verifies provenance fields, finite same-instrument durations and source
hashes, and counts >5-second valid trials as misses. It cannot judge whether a
video truly shows the claimed event; human evidence review remains required.
It never writes an appliance authorization or claims all hardware tests passed.

## Evidence produced on Windows

- Genuine SSD strategy equivalence tests: four modes pass against the established
  adapter/crop outputs. These test actual model kernels, not mocked detections.
- Two-image OBSERVE runs through the spawned detector worker completed; logs and
  provenance-separated timing JSON are under `outputs/phase5/windows_image_smoke_run02/`
  and `windows_image_timing_summary_run02.json`. Their tiny sample sizes do not
  support tail estimates or predict Pi latency.
- Real loopback Paho/broker command/ack tests passed using a Python receiver.
  No real ESP32 or physical relay timing was measured.
- Deterministic synthetic scenario exercises arrivals, vacancy delay, loss,
  reconnect and reboot. Its fake-clock numbers are not a hardware benchmark.

The final validation run stores another genuine Windows two-image run. Consult
its actual JSONL/summary values rather than a claimed Pi extrapolation. All Pi
capture, inference, memory, CPU, temperature, Wi-Fi and physical arrival-to-output
results remain **PENDING**. No five-second acceptance result is reported.
