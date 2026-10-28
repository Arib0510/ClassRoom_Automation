# Phase 5 safety and failure policy

The current detector is **not demonstrated accurate enough for autonomous mains
control**. Historical best-F1 SSD overlap still misses 41/54 person instances;
production single-pass performance is weaker. All 108 historical physical-zone
observations remain UNKNOWN. No electrical or hardware criterion is passed by
the new software tests.

## Operating modes

| Mode | Implemented behavior | Physical authorization |
| --- | --- | --- |
| OBSERVE | Camera/detection/occupancy telemetry; no command packets or controller hello negotiation | Default; MQTT disabled in supplied config |
| DRY_RUN | Full decisions, separate `/dry_run/command`, SIMULATED acknowledgement | Requires verified compatible firmware and recorded firmware-enforced dry-run isolation; otherwise blocked |
| LIVE_TEST | Full decisions and APPLIED acknowledgements for designated isolated indicators | Verified physical mapping/ownership, isolated loads, evidence bundle and transient operator grant |
| LIVE_APPLIANCE | Full automatic ON/OFF code path | All LIVE_TEST gates plus electrical review, live-test, detection/timing acceptance and appliance ownership evidence |

Only OBSERVE can run through the unattended service launcher. A live CLI run
requires a named operator and an exact phrase containing its freshly generated
session ID **before hardware/network startup**. Grants last at most 600 seconds
(300 default), exist only in memory, and are never restored after a restart.
After expiry, renewals stop and the approved controller-local policy applies.
Do not assume expiry physically switches every appliance OFF.

The safety bundle must match the Phase 5 and base configuration fingerprint,
commissioning checksum, selected mode, authorized operator and firmware checksums.
Required checks have explicit reviewer, timezone-aware review time, evidence file
and matching SHA-256. Missing, changed, expired or malformed evidence blocks
commands. Files and configuration are rechecked; a software boolean or the
arming phrase alone is insufficient. The transport independently enforces mode,
route, schema, session and the real safety interlock. Synthetic interlocks work
only with network-incapable MemoryTransport.

Evidence requirements are implemented in `phase5_safety.py`:

- LIVE_TEST: `physical_mapping`, `firmware_protocol`, `isolated_outputs`,
  `watchdog_test`, `manual_override_test`.
- LIVE_APPLIANCE adds `electrical_review`, `live_test_acceptance`,
  `detection_acceptance`, `timing_acceptance`, `appliance_ownership`.

These are human evidence assertions bound to files, not software proof of wiring,
reviewer qualifications or truthfulness. Actual mains installation/inspection
must be performed by a qualified person and approved by the responsible operator.
No safety authorization exists in the delivered example configuration/templates.

## State transitions

| Event | Temporal state | Desired/command behavior |
| --- | --- | --- |
| VACANT -> positive evidence | Wait for two distinct frames across ≥0.5 s | ON only after OCCUPIED confirmation and all interlocks |
| UNKNOWN -> positive | Same fresh confirmation | No stale previous hits reused |
| OCCUPIED -> covered no-person evidence | Remain OCCUPIED until ≥3 distinct frames across ≥10 s | Then OFF after configured extra appliance delay |
| UNKNOWN -> covered no-person evidence | Require the full vacancy confirmation | UNKNOWN is never assumed vacant |
| OCCUPIED/VACANT -> UNKNOWN | Immediately reset candidate evidence | No guessed OFF; cancel pending retries and stop lease renewal |
| Observation age ≥4 s | UNKNOWN | No fresh command authority from stale data |
| Conflicting/unmapped person or invalid frame | UNKNOWN conservatively across zones | No physical image split fallback |
| Valid recovery | Reconfirm states from distinct captures | Reconcile against fresh controller status/ack |

The ten-second vacancy delay reduces flicker but does not cure false negatives.
Verified coverage is required even to generate raw VACANT. It must reflect the
actual frame, visibility and detector strategy. Flat-image checking is only a
basic diagnostic; covered/blurred/noisy cameras are not comprehensively detected.

## Fault matrix and independent controller policy

| Fault | Pi implementation | Independently required ESP32 behavior |
| --- | --- | --- |
| Pi exits/crashes/loses power | May send no final packet at all | Expire local command leases; use approved appliance-specific fallback |
| Camera disconnects/timeouts | UNKNOWN, bounded restart attempts, then stop run | Do not renew lease on unrelated messages |
| Detector/native call hangs | Parent continues ticks; timeout kills worker and invalidates observations | Lease must expire without Pi cooperation |
| Pipeline/RSS/available-memory breach | Disable selected strategy, UNKNOWN and terminate; no automatic costly-mode fallback | Maintain approved fault policy |
| MQTT broker/Wi-Fi loss | Pending/reported state invalidated, no disconnected buffering of decisions | Independently enforce disconnect/expiry policy |
| Pi process restart | New session, no grant, UNKNOWN startup | Reject old session/boot packets |
| ESP32 reboot | New boot must answer a new challenge before commands | Verified startup defaults, new boot ID and local mode |
| Controller reconnect/status stale | New challenge; reported state UNKNOWN | Fresh nonretained status, no retained online shortcut |
| Delayed/lost ack | Bounded same-ID retries, timeout latch | Idempotent acknowledgement; do not extend lease for a duplicate |
| Duplicate/replayed/out-of-order command | Pi validates feedback order; reference tests exercise rejection | Actual firmware must enforce schema/session/sequence/expiry and immutable command IDs |
| Calibration missing/changed/ambiguous | UNKNOWN and command gate closed | No image-quadrant assumption |
| Output disagrees with desired | Failure latched; reported state kept separate | Publish honest feedback; investigate circuit/firmware before clearing |
| UTC correction >0.5 s relative to monotonic | Command clock validity revoked; require a new reviewed run | Invalidate leases on material clock corrections |

The reference receiver tests explicit HOLD/OFF/ON local policies. None is selected
for the real installation. Different appliances/circuits may need different
fallbacks. A Pi cannot reliably send OFF after power loss. MQTT Last Will is useful
diagnostic information but cannot replace a local expiry timer or electrical
protection. Broker credentials/TLS/ACLs and one authorized publisher are required;
session nonces do not protect against a fully compromised authorized publisher.

## Manual requests

Local operator files are optional and bounded. Start a supervised run with
`--override-file /path/to/operator-request.json`, obtain its session ID from logs,
and create a NEW request file on that same Pi:

```bash
.venv-phase5/bin/python -m src.phase5_runtime request --session SESSION_FROM_LOG \
  --operator APPROVED_OPERATOR --action override --appliance VERIFIED_APPLIANCE_ID \
  --state OFF --output /path/to/operator-request.json
```

Use `--state AUTO` to return to automatic decisions, or `--action clear_fault`
with the appliance ID for an explicit fault reset. Files expire after 30 seconds;
the engine also bounds override lifetime. Live override operators must match the
session grant. Overrides cannot bypass mode/evidence/clock/ownership gates or
activate from UNKNOWN occupancy. Requests have unique IDs and are processed once;
after 128 requests, start a new reviewed session. Restrict write access to the
application account. Archive an old request before publishing another at the
watched filename; never replace unrelated configuration or evidence.

## Current real-world status

Firmware source, wiring, relay polarity/ratings, watchdog policy, actual topics,
physical calibration and acceptance evidence are unresolved. No real-controller
or appliance safety enforcement is claimed. All hardware and real-appliance
acceptance remains PENDING; software tests do not authorize commissioning.
