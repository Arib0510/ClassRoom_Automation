# Phase 5 MQTT protocol and ESP32 integration specification

## Verified status and migration boundary

No ESP32 firmware, protocol implementation, GPIO table, relay polarity, ownership
record or watchdog behavior was available. The prior `docs/esp32_integration.md`
is explicitly an unverified **telemetry** receiver proposal. Its existing `/state`
QoS-0 nonretained snapshots and `/availability` retained process status are
unchanged. They do not implement the new acknowledgement protocol.

Phase 5 implements **`classroom-control-v1`**, an explicitly proposed adapter on a
separate configurable prefix. Default `classroom/phase5/uncommissioned` has MQTT
disabled and zero controllers. Inspect the actual firmware first. Either adapt
that firmware to the specification below, or add a tested adapter for its actual
protocol; do not point this publisher at guessed existing actuation topics.

## Topics and transport

For a configured prefix `P` and a verified controller ID `C`:

| Topic | Direction | QoS | Retained | Meaning |
| --- | --- | --- | --- | --- |
| `P/telemetry` | Pi -> diagnostics | 0 | No | Zone/state/reason/decision observations |
| `P/pi/availability` | Pi -> observers | 1 | Yes | Process presence and Last Will, not output evidence |
| `P/controllers/C/hello` | Pi -> compatible controller | 0 | No | Fresh binding challenge |
| `P/controllers/C/status` | Controller -> Pi | subscribe 1 | Must be No | Fresh heartbeat, boot and logical output inventory |
| `P/controllers/C/dry_run/command` | Pi -> compatible controller | configured 0/1 | No | Firmware-enforced non-actuating test command |
| `P/controllers/C/command` | Pi -> verified isolated/live controller | configured 0/1 | No | Authorized leased desired output |
| `P/controllers/C/ack` | Controller -> Pi | subscribe 1 | Must be No | Command acceptance and reported output |

QoS 0 is the default command QoS; application acknowledgements and bounded retries
repair loss. QoS 1 is available but the receiver must still handle duplicate and
delayed packets. The Pi bounds Paho in-flight messages to one and queued messages
to two, drops new publication when its outstanding packet is not sent, and bounds
received messages to 128 × 16 KiB. It does not keep an unbounded command backlog.
Reconnect uses a 1-to-10 second Paho backoff and a new challenge. Commands are
always nonretained. An old queued/in-flight packet is still potentially deliverable;
receiver binding and absolute expiry must reject it.

The [Paho client API](https://eclipse.dev/paho/files/paho.mqtt.python/html/client.html)
defines these transport settings. The implementation uses Paho 2.1.0 callback API
VERSION2, MQTT 3.1.1, a unique session-suffixed client ID, environment-supplied
credentials and optional validated TLS. No credential is logged. Broker ACLs
must restrict one authorized Pi publisher to its assigned command topics, and
each controller to its status/ack topics and own commands. Require isolation and
TLS according to the actual network risk; a nonce is not an authentication secret.

## Message schemas

Every message has `protocol: "classroom-control-v1"`, a `kind`, and integer Unix
millisecond `sent_at_unix_ms` / `expires_at_unix_ms`. Pi and controller UTC clocks
must be synchronized and validated. Maximum accepted message lease is four
seconds; default command lease is three seconds and also cannot exceed remaining
sensor freshness. Future-time tolerance is 250 ms and never extends expiry.
Reject bools in integer fields, malformed JSON, duplicate JSON keys, NaN, unknown
fields in command/feedback schemas, oversized messages and unknown ownership.

`hello` has exactly:

```json
{
  "protocol": "classroom-control-v1", "kind": "hello",
  "session_id": "new-pi-session", "challenge": "fresh-connection-nonce",
  "sent_at_unix_ms": 1800000000000, "expires_at_unix_ms": 1800000003000
}
```

These timestamps and identifiers are schema examples, not live instructions.
`status` adds controller identity and a fresh sequence:

```json
{
  "protocol": "classroom-control-v1", "kind": "status",
  "controller_id": "configured-controller", "controller_boot_id": "fresh-controller-boot",
  "session_id": "new-pi-session", "challenge": "fresh-connection-nonce", "sequence": 1,
  "sent_at_unix_ms": 1800000000000, "expires_at_unix_ms": 1800000003000,
  "clock_valid": true, "outputs": {"configured-appliance": "UNKNOWN"}
}
```

The output dictionary must contain exactly that controller's configured appliance
IDs, each ON/OFF/UNKNOWN. Emit a nonretained status at least once per second and
after restart/reconnect. A retained online/status record cannot establish current
connectivity. A new controller boot triggers a new challenge before commands.

A command has exactly:

```json
{
  "protocol": "classroom-control-v1", "kind": "command",
  "session_id": "new-pi-session", "challenge": "fresh-connection-nonce",
  "controller_id": "configured-controller", "controller_boot_id": "fresh-controller-boot",
  "command_id": "unique-command-id", "sequence": 1,
  "appliance_id": "configured-appliance", "channel": "verified-logical-channel",
  "desired_state": "ON", "mode": "DRY_RUN", "require_ack": true,
  "sent_at_unix_ms": 1800000000000, "expires_at_unix_ms": 1800000003000
}
```

`channel` is a verified firmware logical channel, never a guessed GPIO or level.
The board translates ON/OFF to its physically verified polarity. DRY_RUN commands
use only the dry-run topic, and firmware must independently enforce no GPIO
transition regardless of requested desired state. Pin firmware mode at startup;
do not allow a packet alone to promote DRY_RUN to LIVE_TEST or LIVE_APPLIANCE.

`ack` has the status envelope fields (without clock_valid/outputs), plus:

```json
{
  "command_id": "unique-command-id", "command_sequence": 1,
  "appliance_id": "configured-appliance", "desired_state": "ON",
  "result": "SIMULATED", "actual_state": "UNKNOWN"
}
```

Result is SIMULATED for DRY_RUN and APPLIED or REJECTED otherwise. APPLIED requires
reported logical output to agree with the requested state. It is not evidence of
relay contact closure, load current or room lighting. Independent sensing/external
observation is required for physical activation timing. Pi durations use its own
monotonic publish/receive times; ESP32 `millis()` values are never subtracted from
Pi time.

## Required firmware algorithm — NOT flashed or verified

1. Establish electrically approved startup defaults locally. Reject commands
   before a valid clock and fresh hello/status exchange. Acknowledge only the
   intended Pi session and its current challenge; use a new board boot ID on boot.
2. On a fresh challenge/session, invalidate old leases and use the explicitly
   approved local fault policy. Keep a bounded retired-challenge history; when
   exhausted, fail closed instead of forgetting replay protection. Duplicate
   identical hellos must not reset the command sequence high-water mark.
3. Reject retained commands; wrong topic, mode, ownership, session, challenge,
   controller boot, stale UTC expiry, implausibly future issue time or nonincreasing
   sequence. A controller reboot changes boot ID, so an old command cannot bind.
4. For an identical current command, acknowledge idempotently without another
   output transition or extending its original lease. A reused ID with changed
   content must be rejected. Out-of-order commands must not roll state backward.
5. Store the smaller of remaining absolute expiry and approved local receive
   watchdog as a monotonic local deadline. Check it continuously even if MQTT
   pings or unrelated telemetry continue. Revoke on clock corrections, disconnect
   or controller faults. Use wrap-safe `millis()` arithmetic.
6. Apply ONLY verified channel ownership/polarity in the board's locally selected
   mode. On expiry invoke the appliance-specific local policy, not a universal
   assumed OFF. Publish a nonretained matching acknowledgement after reporting
   the logical transition; independent feedback remains a separate fact.
7. Renew state only on a newly accepted, fresh, higher-sequence command. A retry
   does not refresh a lease. Repeated invalid messages do not refresh any watchdog.

`ReferenceController` implements a bounded Python test version with **no GPIO**.
Its HOLD/OFF/ON policy examples test protocol semantics, not the actual circuit's
safe choice. The real firmware may need a different approved local policy.

## Reconciliation and failure behavior

Pi state stores desired, reported, reported_at, pending ID, lease deadline and
failure separately. It retries the same command at the acknowledgement timeout
(one second default), at most two accepted publications by default. A timeout or
reported disagreement latches a failure until an operator clear or a changed
desired state; no endless correction loop occurs. Minimum publish spacing is
0.5 seconds per appliance. New IDs renew unchanged desired states before their
lease expires. Unknown/stale occupancy stops renewals rather than sending a
guessed OFF. Reconnect discards pending/reported state and requires fresh status.

The real transport additionally validates outgoing command schema, mode, route,
inventory, current clock-valid status and the actual session safety interlock.
The synthetic simulation interlock cannot bind to a real MQTT transport.

## Pending firmware handoff

- Obtain source/binary version/hash, broker configuration and exact existing topic
  schemas, channel/GPIO table, polarity, appliance ownership and startup/watchdog rules.
- Resolve whether to adapt existing firmware or migrate to this protocol.
- Verify dry-run isolation, replay/order/expiry behavior, mode pinning, reboot
  defaults, manual override and local fault policy on isolated test outputs.
- Add firmware evidence/checksum to controller inventory only after review.
- Test the Pi's acknowledgement/reconciliation code against the actual board.

Real local-broker/Paho tests passed on Windows with the reference receiver. This
does not establish ESP32 compatibility, actual Wi-Fi reliability or electrical safety.
