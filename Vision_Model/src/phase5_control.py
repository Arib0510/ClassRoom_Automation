"""Occupancy -> desired state -> interlock -> leased commands -> acknowledgement reconciliation."""

from __future__ import annotations

import math
import uuid

from .phase5_config import number
from .phase5_protocol import decode, envelope, fresh
from .zones import ZONE_IDS


class ApplianceEngine:
    def __init__(self, config, transport, interlock, session_id, *, clock_valid=False, token=None):
        self.config, self.transport, self.interlock, self.session_id = (
            config,
            transport,
            interlock,
            session_id,
        )
        self.token = token or (lambda: uuid.uuid4().hex)
        self.clock_valid = clock_valid
        if hasattr(transport, "bind_interlock"):
            transport.bind_interlock(interlock, lambda: self.clock_valid)
        self.sequence = 0
        self.generation = None
        self.controllers = {}
        self.controller_latches = set()  # At most one entry per configured controller.
        self.appliances = {a["id"]: a for a in config.data["appliances"]}
        self.states = {
            a: {
                "desired": None,
                "reported": "UNKNOWN",
                "reported_at": None,
                "pending": None,
                "confirmed_until": 0,
                "last_publish": -math.inf,
                "vacant_since": None,
                "failure": None,
                "reason": "startup",
            }
            for a in self.appliances
        }
        self.overrides = {}
        self.events = []
        self.last_now = self.last_unix = None
        self.counters = dict(
            published=0, acknowledgements=0, invalid_messages=0, command_failures=0, reconnects=0
        )

    def event(self, kind, **fields):
        self.events.append({"event": kind, **fields})
        self.events = self.events[-128:]

    def override(self, appliance_id, state, operator, expires_at, now):
        if (
            appliance_id not in self.appliances
            or state not in ("ON", "OFF", "AUTO")
            or not operator.strip()
        ):
            raise ValueError("Invalid local manual override")
        number(expires_at - now, "override duration", 0.01, 300)
        grant = getattr(self.interlock, "grant", None)
        if self.config.mode.startswith("LIVE") and (grant is None or grant.operator != operator):
            raise ValueError("Override operator must match current session grant")
        self.overrides[appliance_id] = (state, operator, expires_at)

    def clear_fault(self, aid, operator):
        if aid not in self.states or not operator.strip():
            raise ValueError("Named operator required to clear a known appliance fault")
        self.states[aid]["failure"] = None

    def disconnected(self):
        self.controllers.clear()
        for state in self.states.values():
            state.update(reported="UNKNOWN", reported_at=None, pending=None, confirmed_until=0)

    def _reset_connection(self, now, unix):
        self.disconnected()
        self.generation = self.transport.generation
        self.counters["reconnects"] += 1
        for controller in self.config.data["controllers"]:
            self.controllers[controller["id"]] = {
                "challenge": self.token(),
                "boot": None,
                "sequence": -1,
                "last_seen": None,
                "hello_at": -math.inf,
                "retired_boots": set(),
            }
        self.event("mqtt_generation", generation=self.generation, now=now)

    def _hello(self, cid, state, now, unix):
        if now - state["hello_at"] < 1:
            return
        packet = envelope(
            "hello",
            session_id=self.session_id,
            challenge=state["challenge"],
            sent_at_unix_ms=int(unix * 1000),
            expires_at_unix_ms=int((unix + 3) * 1000),
        )
        if self.transport.publish(
            f"{self.config.data['mqtt']['prefix']}/controllers/{cid}/hello", packet, 0
        ):
            state["hello_at"] = now

    def receive(self, topic, payload, retained, now, unix):
        try:
            if retained:
                raise ValueError("Retained feedback cannot establish connectivity/output state")
            message = decode(payload)
            cid = message["controller_id"]
            c = self.controllers[cid]
            if cid in self.controller_latches:
                raise ValueError("Controller reboot budget latched; new reviewed run required")
            kind = message["kind"]
            expected_topic = f"{self.config.data['mqtt']['prefix']}/controllers/{cid}/{kind}"
            common = {
                "protocol",
                "kind",
                "controller_id",
                "controller_boot_id",
                "session_id",
                "challenge",
                "sequence",
                "sent_at_unix_ms",
                "expires_at_unix_ms",
            }
            expected_fields = common | (
                {"clock_valid", "outputs"}
                if kind == "status"
                else {
                    "command_id",
                    "command_sequence",
                    "appliance_id",
                    "desired_state",
                    "result",
                    "actual_state",
                }
            )
            if (
                kind not in ("status", "ack")
                or set(message) != expected_fields
                or topic != expected_topic
                or message["session_id"] != self.session_id
                or message["challenge"] != c["challenge"]
                or not fresh(message, unix)
            ):
                raise ValueError("Feedback schema/topic/session/lease mismatch")
            number(message["sequence"], "feedback sequence", 1, 2**53, True)
            boot = message["controller_boot_id"]
            if (
                not isinstance(boot, str)
                or not boot
                or len(boot) > 64
                or boot in c["retired_boots"]
            ):
                raise ValueError("Invalid or retired controller boot")
            if kind == "status":
                outputs = message["outputs"]
                owned = {
                    a for a, mapping in self.appliances.items() if mapping["controller"] == cid
                }
                if (
                    message["clock_valid"] is not True
                    or not isinstance(outputs, dict)
                    or set(outputs) != owned
                    or any(s not in ("ON", "OFF", "UNKNOWN") for s in outputs.values())
                ):
                    raise ValueError("Controller clock or output inventory invalid")
                if c["boot"] is not None and boot != c["boot"]:
                    # Reboot requires a NEW challenge; never accept a new boot on old binding.
                    if len(c["retired_boots"]) >= 16:
                        self.controller_latches.add(cid)
                        c.update(boot=None, last_seen=None)
                        for aid in owned:
                            self.states[aid].update(reported="UNKNOWN", reported_at=None)
                            self._failure(aid, "controller_reboot_budget_exceeded", now)
                        raise ValueError("Controller reboot budget exceeded; restart commissioning")
                    c["retired_boots"].add(c["boot"])
                    c.update(
                        boot=None,
                        challenge=self.token(),
                        sequence=-1,
                        last_seen=None,
                        hello_at=-math.inf,
                    )
                    for aid in owned:
                        self.states[aid].update(
                            reported="UNKNOWN", reported_at=None, pending=None, confirmed_until=0
                        )
                    return False
                if message["sequence"] <= c["sequence"]:
                    raise ValueError("Duplicate/out-of-order status")
                c.update(boot=boot, sequence=message["sequence"], last_seen=now)
                for aid, actual in outputs.items():
                    self.states[aid].update(reported=actual, reported_at=now)
            else:
                if boot != c["boot"] or message["sequence"] <= c["sequence"]:
                    raise ValueError("Stale acknowledgement binding/order")
                aid = message["appliance_id"]
                number(message["command_sequence"], "ack command sequence", 1, 2**53, True)
                if self.appliances[aid]["controller"] != cid:
                    raise ValueError("Ack ownership mismatch")
                state = self.states[aid]
                pending = state["pending"]
                if (
                    pending is None
                    or now >= pending["deadline"]
                    or message["command_id"] != pending["packet"]["command_id"]
                    or message["command_sequence"] != pending["packet"]["sequence"]
                    or message["desired_state"] != pending["packet"]["desired_state"]
                ):
                    raise ValueError("Unexpected, expired or old acknowledgement")
                expected_result = "SIMULATED" if self.config.mode == "DRY_RUN" else "APPLIED"
                if message["result"] != expected_result or message["actual_state"] not in (
                    "ON",
                    "OFF",
                    "UNKNOWN",
                ):
                    self._failure(aid, "controller_rejected_command", now)
                    return False
                if (
                    expected_result == "APPLIED"
                    and message["actual_state"] != message["desired_state"]
                ):
                    self._failure(aid, "output_disagrees_with_desired", now)
                    return False
                c.update(sequence=message["sequence"], last_seen=now)
                state.update(pending=None, confirmed_until=pending["deadline"])
                if expected_result == "APPLIED":
                    state.update(reported=message["actual_state"], reported_at=now)
                self.counters["acknowledgements"] += 1
                self.event(
                    "controller_ack",
                    appliance_id=aid,
                    now=now,
                    acknowledgement_seconds=now - pending["first_publish"],
                    result=message["result"],
                    physical_transition_seconds=None,
                )
            return True
        except (ValueError, TypeError, KeyError, UnicodeError):
            self.counters["invalid_messages"] += 1
            return False

    def _failure(self, aid, reason, now):
        self.states[aid].update(failure=reason, pending=None, confirmed_until=0)
        self.counters["command_failures"] += 1
        self.event("command_failure", appliance_id=aid, reason=reason, now=now)

    def step(self, snapshot, now, unix):
        if set(snapshot) != set(ZONE_IDS) or not math.isfinite(now) or not math.isfinite(unix):
            raise ValueError("Four zones and finite clocks required")
        if self.last_now is not None:
            if now < self.last_now:
                raise ValueError("Control monotonic clock moved backwards")
            if abs((unix - self.last_unix) - (now - self.last_now)) > 0.5:
                self.clock_valid = False
                self.disconnected()
                self.event("clock_correction", now=now)
        self.last_now, self.last_unix = now, unix
        online = self.transport.connected
        if online and self.generation != self.transport.generation:
            self._reset_connection(now, unix)
        if not online:
            self.disconnected()
            self.generation = None
        for topic, payload, retained in self.transport.drain():
            if online and self.clock_valid:
                self.receive(topic, payload, retained, now, unix)
        mqtt = self.config.data["mqtt"]
        if online and self.clock_valid and self.config.mode != "OBSERVE":
            for cid, c in self.controllers.items():
                if cid in self.controller_latches:
                    continue
                owned = [a for a in self.appliances.values() if a["controller"] == cid]
                if not any(self.interlock.permits(a, now, unix)[0] for a in owned):
                    # Session negotiation also requires compatible, authorized hardware.
                    continue
                if (
                    c["last_seen"] is not None
                    and now - c["last_seen"] >= mqtt["status_timeout_seconds"]
                ):
                    c.update(
                        boot=None,
                        last_seen=None,
                        sequence=-1,
                        challenge=self.token(),
                        hello_at=-math.inf,
                    )
                    for aid, mapping in self.appliances.items():
                        if mapping["controller"] == cid:
                            self.states[aid].update(
                                reported="UNKNOWN",
                                reported_at=None,
                                pending=None,
                                confirmed_until=0,
                            )
                if c["boot"] is None:
                    self._hello(cid, c, now, unix)
        for aid, mapping in self.appliances.items():
            state, zone = self.states[aid], snapshot[mapping["zone"]]
            age = None if zone.get("observed_at") is None else now - zone["observed_at"]
            valid = (
                zone["state"] in ("OCCUPIED", "VACANT")
                and age is not None
                and 0 <= age < self.config.base.occupancy.stale_seconds
            )
            want = None
            if valid:
                if zone["state"] == "OCCUPIED":
                    want = "ON"
                    state["vacant_since"] = None
                else:
                    if state["vacant_since"] is None:
                        state["vacant_since"] = now
                    if now - state["vacant_since"] >= mapping["off_delay_seconds"]:
                        want = "OFF"
                override = self.overrides.get(aid)
                if override is not None:
                    if now >= override[2]:
                        del self.overrides[aid]
                    elif override[0] != "AUTO":
                        want = override[0]
            else:
                state["vacant_since"] = None
            if want != state["desired"]:
                state.update(desired=want, pending=None, confirmed_until=0, failure=None)
                self.event("desired_state", appliance_id=aid, desired=want, now=now)
            allowed, reason = self.interlock.permits(mapping, now, unix)
            state["reason"] = (
                reason
                if not allowed
                else ("occupancy_unknown" if want is None else "decision_ready")
            )
            if (
                not allowed
                or not valid
                or want is None
                or not online
                or not self.clock_valid
                or state["failure"] is not None
            ):
                state["pending"] = None  # Never retry revoked or unknown evidence.
                continue
            controller = self.controllers.get(mapping["controller"])
            if controller is None or controller["boot"] is None:
                state["reason"] = "controller_unavailable"
                continue
            pending = state["pending"]
            if pending and now >= pending["deadline"]:
                self._failure(aid, "command_expired_without_ack", now)
                continue
            if pending and now - pending["last_publish"] >= mqtt["ack_timeout_seconds"]:
                if pending["attempts"] >= mqtt["max_attempts"]:
                    self._failure(aid, "acknowledgement_timeout", now)
                    continue
            elif pending:
                continue
            if now - state["last_publish"] < mqtt["min_command_interval_seconds"]:
                continue
            if not pending:
                if state["confirmed_until"] - now > mqtt["lease_seconds"] / 2 and (
                    self.config.mode == "DRY_RUN" or state["reported"] == want
                ):
                    continue
                remaining = min(
                    mqtt["lease_seconds"], self.config.base.occupancy.stale_seconds - age
                )
                if remaining <= 0.05:
                    continue
                self.sequence += 1
                packet = envelope(
                    "command",
                    session_id=self.session_id,
                    challenge=controller["challenge"],
                    controller_id=mapping["controller"],
                    controller_boot_id=controller["boot"],
                    command_id=self.token(),
                    sequence=self.sequence,
                    appliance_id=aid,
                    channel=mapping["channel"],
                    desired_state=want,
                    mode=self.config.mode,
                    sent_at_unix_ms=int(unix * 1000),
                    expires_at_unix_ms=int((unix + remaining) * 1000),
                    require_ack=True,
                )
                pending = {
                    "packet": packet,
                    "deadline": now + remaining,
                    "first_publish": now,
                    "last_publish": -math.inf,
                    "attempts": 0,
                }
            suffix = "dry_run/command" if self.config.mode == "DRY_RUN" else "command"
            topic = f"{mqtt['prefix']}/controllers/{mapping['controller']}/{suffix}"
            if self.transport.publish(topic, pending["packet"], mqtt["command_qos"]):
                pending["attempts"] += 1
                pending["last_publish"] = now
                state.update(pending=pending, last_publish=now)
                self.counters["published"] += 1
                self.event(
                    "command_published",
                    appliance_id=aid,
                    now=now,
                    command_id=pending["packet"]["command_id"],
                    mqtt_enqueue_seconds=getattr(self.transport, "last_publish_seconds", None),
                )
        return {
            aid: {k: v for k, v in state.items() if k != "pending"}
            | {
                "pending_command_id": None
                if state["pending"] is None
                else state["pending"]["packet"]["command_id"]
            }
            for aid, state in self.states.items()
        }
