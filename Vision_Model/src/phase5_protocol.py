"""Proposed versioned command adapter and SOFTWARE reference receiver, never ESP32 firmware."""

from __future__ import annotations

import json
from collections import deque

from .phase5_config import PROTOCOL, identifier, number


def decode(payload: bytes | str) -> dict:
    if len(payload) > 16_384:
        raise ValueError("MQTT payload exceeds bound")

    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("Duplicate JSON key")
            result[key] = value
        return result

    value = json.loads(
        payload,
        object_pairs_hook=pairs,
        parse_constant=lambda s: (_ for _ in ()).throw(ValueError(s)),
    )
    if not isinstance(value, dict) or value.get("protocol") != PROTOCOL:
        raise ValueError("Unsupported protocol")
    return value


def envelope(kind, **fields):
    return {"protocol": PROTOCOL, "kind": kind, **fields}


def fresh(message, unix, maximum_ms=4000):
    for field in ("sent_at_unix_ms", "expires_at_unix_ms"):
        number(message[field], field, 0, 2**53, True)
    sent, expiry = message["sent_at_unix_ms"], message["expires_at_unix_ms"]
    return sent <= unix * 1000 + 250 and unix * 1000 < expiry and 0 < expiry - sent <= maximum_ms


def validate_command(message, appliances, unix):
    required = {
        "protocol",
        "kind",
        "session_id",
        "challenge",
        "controller_id",
        "controller_boot_id",
        "command_id",
        "sequence",
        "appliance_id",
        "channel",
        "desired_state",
        "mode",
        "sent_at_unix_ms",
        "expires_at_unix_ms",
        "require_ack",
    }
    if set(message) != required or message["protocol"] != PROTOCOL or message["kind"] != "command":
        raise ValueError("Invalid command schema")
    for key in (
        "session_id",
        "challenge",
        "controller_id",
        "controller_boot_id",
        "command_id",
        "appliance_id",
        "channel",
    ):
        identifier(message[key])
    number(message["sequence"], "sequence", 1, 2**53, True)
    if (
        message["desired_state"] not in ("ON", "OFF")
        or message["mode"] not in ("DRY_RUN", "LIVE_TEST", "LIVE_APPLIANCE")
        or message["require_ack"] is not True
        or not fresh(message, unix)
    ):
        raise ValueError("Invalid/expired command")
    appliance = appliances.get(message["appliance_id"])
    if appliance is None or (message["controller_id"], message["channel"]) != (
        appliance["controller"],
        appliance["channel"],
    ):
        raise ValueError("Command ownership mismatch")


class ReferenceController:
    """Deterministic emulator. Implements NO GPIO and is NOT deployable ESP32 enforcement."""

    def __init__(self, controller_id, boot_id, appliances, local_policy="HOLD", mode="DRY_RUN"):
        if local_policy not in ("HOLD", "OFF", "ON"):
            raise ValueError("Reference local policy must be explicitly selected")
        self.id, self.boot, self.appliances, self.policy, self.mode = (
            controller_id,
            boot_id,
            appliances,
            local_policy,
            mode,
        )
        self.session = self.challenge = None
        self.sequence = 0
        self.last_command = 0
        self.retired = deque(maxlen=32)
        self.outputs = {a: "UNKNOWN" for a, p in appliances.items() if p["controller"] == self.id}
        self.leases = {}
        self.accepted = {}  # Bounded by appliance inventory, no unbounded command history.

    def hello(self, hello, unix):
        if (
            hello.get("protocol") != PROTOCOL
            or hello.get("kind") != "hello"
            or not fresh(hello, unix)
            or hello["challenge"] in self.retired
        ):
            raise ValueError("Invalid/replayed challenge")
        if self.challenge is not None and (self.session, self.challenge) != (
            hello["session_id"],
            hello["challenge"],
        ):
            if len(self.retired) == self.retired.maxlen:
                raise ValueError("Reference challenge history full; require recommissioned session")
            self.retired.append(self.challenge)
            self.fault()
        if (self.session, self.challenge) != (hello["session_id"], hello["challenge"]):
            self.last_command = 0
        self.session, self.challenge = hello["session_id"], hello["challenge"]
        return self.status(unix)

    def status(self, unix):
        self.sequence += 1
        return envelope(
            "status",
            controller_id=self.id,
            controller_boot_id=self.boot,
            session_id=self.session,
            challenge=self.challenge,
            sequence=self.sequence,
            sent_at_unix_ms=int(unix * 1000),
            expires_at_unix_ms=int((unix + 3) * 1000),
            clock_valid=True,
            outputs=dict(self.outputs),
        )

    def command(self, message, now, unix, *, retained=False, dry_topic=False):
        validate_command(message, self.appliances, unix)
        if (
            retained
            or message["controller_id"] != self.id
            or message["session_id"] != self.session
            or message["challenge"] != self.challenge
            or message["controller_boot_id"] != self.boot
            or (message["mode"] == "DRY_RUN") != dry_topic
            or message["mode"] != self.mode
        ):
            raise ValueError("Controller binding/mode/retained violation")
        aid = message["appliance_id"]
        prior = self.accepted.get(aid)
        if prior and message == prior[0]:
            # Idempotent ack; duplicate does NOT renew the physical lease.
            return self._ack(message, unix)
        if prior and message["command_id"] == prior[0]["command_id"]:
            raise ValueError("Command ID reused with changed payload")
        if message["sequence"] <= self.last_command:
            raise ValueError("Out-of-order or mutated duplicate command")
        self.last_command = message["sequence"]
        self.accepted[aid] = (dict(message), now)
        if self.mode != "DRY_RUN":
            self.outputs[aid] = message["desired_state"]
            self.leases[aid] = now + (message["expires_at_unix_ms"] / 1000 - unix)
        return self._ack(message, unix)

    def _ack(self, message, unix):
        self.sequence += 1
        return envelope(
            "ack",
            controller_id=self.id,
            controller_boot_id=self.boot,
            session_id=self.session,
            challenge=self.challenge,
            sequence=self.sequence,
            sent_at_unix_ms=int(unix * 1000),
            expires_at_unix_ms=int((unix + 3) * 1000),
            command_id=message["command_id"],
            command_sequence=message["sequence"],
            appliance_id=message["appliance_id"],
            desired_state=message["desired_state"],
            result="SIMULATED" if self.mode == "DRY_RUN" else "APPLIED",
            actual_state=self.outputs[message["appliance_id"]],
        )

    def fault(self):
        for aid in self.outputs:
            if self.policy != "HOLD":
                self.outputs[aid] = self.policy
        self.leases.clear()
        self.accepted.clear()

    def tick(self, now):
        for aid, deadline in list(self.leases.items()):
            if now >= deadline:
                if self.policy != "HOLD":
                    self.outputs[aid] = self.policy
                del self.leases[aid]
