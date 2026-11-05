# ESP32 integration contract

## Transport and controller ownership

All devices join the classroom Wi-Fi and connect to the **same existing LAN MQTT
broker**. MQTT is TCP, version 3.1.1. Every Pi/ESP32 needs a unique client ID.
ESP32 DevKit V1 firmware must be adapted to this contract before live use; the
existing firmware and actuator wiring were not provided or tested today.

The Pi publishes the full four-zone state; each ESP32 consumes only its assigned
quadrants. Keep mapping in controller firmware/configuration, not in the detector.
Suggested assignments to review against the existing installation:

| Controllers | Controller | Assigned zones |
| --- | --- | --- |
| Two | A | `front_left`, `front_right` |
| Two | B | `back_left`, `back_right` |
| Three | A | `front_left`, `front_right` |
| Three | B | `back_left` |
| Three | C | `back_right` |

A controller can drive independent outputs per assigned quadrant. If it has one
shared output, combine assigned states as: any occupied -> occupied; all vacant ->
vacant; otherwise -> unknown. Do not turn unknown into vacant. Actual actuator
behavior on unknown/offline is an explicit commissioning decision for the existing
firmware. The Pi publishes observations, not relay GPIO levels or mains commands.

## Topics

Default prefix: `classroom/classroom-01/vision`.

| Topic suffix | Publish QoS | Retained | Purpose |
| --- | --- | --- | --- |
| `/state` | 0 | No | Full snapshot on change, reconnect or 2-second heartbeat |
| `/availability` | 1 | Yes | Process online/offline; offline is also the Last Will |

Subscribers may request QoS 1, but state remains QoS 0 because that is the publisher
QoS. Heartbeats repair a dropped snapshot. New subscribers wait for the next
heartbeat. Telemetry is dropped while disconnected and is not stored for replay.
The publisher bounds unsent telemetry to one packet. TCP/broker buffering can still
delay a packet, so receiver expiry remains mandatory.

An availability message is:

```json
{"schema_version":1,"device_id":"classroom-01-vision","boot_id":"7c32-example","online":true}
```

`online:false` means the process disconnected or the broker emitted its Last Will.
The retained online message may outlive usable observations. It must never be used
as evidence that a quadrant is vacant or that a sensor is healthy.

## State payload, schema version 1

```json
{
  "schema_version": 1,
  "device_id": "classroom-01-vision",
  "boot_id": "7c32-example",
  "sequence": 17,
  "sent_at": "2026-10-25T06:00:00.000+00:00",
  "sent_at_unix_ms": 1792908000000,
  "expires_at_unix_ms": 1792908003600,
  "observation_age_ms": 400,
  "zones": {
    "front_left": {"state":"occupied","person_count":2,"last_seen_age_ms":400},
    "front_right": {"state":"vacant","person_count":0,"last_seen_age_ms":null},
    "back_left": {"state":"unknown","person_count":null,"last_seen_age_ms":null},
    "back_right": {"state":"occupied","person_count":1,"last_seen_age_ms":400}
  }
}
```

Timestamps are Unix milliseconds / UTC. `sequence` increases per attempted snapshot
within a process boot; gaps are normal. `boot_id` changes on process restart, so
sequence 0 from a new boot is valid. Do not compare sequences across boots.
`person_count` is the latest detection count, not a debounced count or census.
`last_seen_age_ms` is time since a positive observation during the current valid
observation run, or null when no positive observation is known.

The expiry is `sent_time + min(mqtt.expiry_seconds,
occupancy.stale_seconds - observation_age)` for a current observation. With defaults
it is at most four seconds into the future and shortens as data ages. Missing or
stale observations force every state to unknown. Startup unknown may have the
eight-second process message lease; it is still unusable as a known occupancy.

Use 64-bit integers for Unix milliseconds and sequence. ArduinoJson can parse the
message, but use a sufficiently sized MQTT buffer (e.g. 2048 bytes including topic
and MQTT overhead) rather than a common library's small default buffer. Check
allocation/parse errors. This buffer size is an initial configuration, not an
ESP32 memory measurement.

## Required receiver logic

1. On boot, Wi-Fi loss, MQTT loss or reconnect, invalidate all assigned states.
   Subscribe to both exact topics on every MQTT connection. Synchronize UTC with
   SNTP and do not apply known occupancy before the clock is valid.
2. For availability, validate schema and expected device ID. Record its boot ID.
   Offline invalidates state immediately. A newly announced boot invalidates old
   state and sequence history; online alone does not produce an actuator update.
   Retain previously seen boot IDs in the running session so late packets cannot
   switch back to a retired boot. After a controller reboot, timestamp expiry and
   newly received availability establish the current session.
3. For state, validate JSON, schema, device ID, all four zone fields and types,
   and boot ID against current online availability. If state arrives first, wait
   for availability and a subsequent heartbeat. Ignore duplicate/out-of-order
   sequence values within a boot. Malformed packets never refresh the watchdog.
4. Check that `sent_at_unix_ms` is not in the future beyond an agreed small clock
   tolerance and that `expires_at_unix_ms` is later than current UTC and not more
   than eight seconds after `sent_at_unix_ms`. Reject stale/delayed snapshots.
   Positive clock tolerance must not extend the expiry. Null observation age or
   an age over four seconds cannot establish occupied/vacant.
5. For every accepted payload, store receipt `millis()` and remaining absolute
   lease. The effective local deadline is the **smaller** of that remaining lease
   and an eight-second receive watchdog. Check deadlines continuously even when
   MQTT pings/online availability continue. Use wrap-safe unsigned subtraction
   for `millis()` arithmetic. If NTP makes a significant clock correction,
   invalidate state and wait for the next fresh snapshot.
6. Apply each assigned quadrant's stable state; skip hardware changes for duplicate
   identical states. On unknown/offline/expiry/missing data, invoke the agreed
   fallback rather than treating the room as empty. Require a newly accepted
   fresh snapshot to recover.

Equivalent high-level loop (integrate into the existing firmware):

```text
onConnect:
    invalidateAssignedZones()
    subscribe(stateTopic)
    subscribe(availabilityTopic)

onState(packet):
    if !validClock || !validSchemaTypesAndDevice(packet): return
    if !onlineAvailability || packet.boot_id != currentBoot: return
    if packet.sequence <= lastSequenceForCurrentBoot: return
    if packet.sent_at is implausibly future || packet.expiry <= utcNow: return
    if packet.expiry - packet.sent_at > 8000ms: return
    if observation age missing or > 4000ms: invalidateAssignedZones(); return
    remainingLease = min(packet.expiry - utcNow, 8000ms)
    acceptedAtMillis = millis()
    lastSequenceForCurrentBoot = packet.sequence
    applyAssignedStates(packet.zones)

loop:
    serviceWiFiAndMQTT()
    if disconnected || unsigned(millis() - acceptedAtMillis) >= remainingLease:
        invalidateAssignedZonesAndUseFallback()
```

`applyAssignedStates` must validate all values and handle `unknown` explicitly.
No ESP32 firmware compilation, flashing, socket exchange, relay action or network
test was performed today. Receiver pseudocode is a protocol guide, not a flashed
controller implementation.

## Broker configuration notes

Give the Pi publish permissions on exactly its state and availability topics and
the ESP32s subscribe permissions. Use the broker's existing credentials and TLS
policy. Enable appropriate broker persistence for retained availability if desired.
There must be only one active publisher for this device/topic identity.

If a previous implementation retained `/state`, clear that old retained record
once during migration using broker administration tools; this application publishes
nonretained state and cannot overwrite an old retained entry. Even without that
cleanup, the receiver must reject old timestamps/boot IDs. Do not accept arbitrary
network JSON as trusted actuator instructions.

Tomorrow verify loss, expiry, duplicates, Pi and ESP32 restarts, broker reboot,
timestamp handling and zone ownership using [the test plan](tomorrow_test_plan.md).
