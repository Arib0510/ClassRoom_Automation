"""Evidence-bound authorization plus a short-lived, nonpersistent operator grant."""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import UTC, datetime

from .phase5_config import Phase5Config, digest, exact

TEST_CHECKS = (
    "physical_mapping",
    "firmware_protocol",
    "isolated_outputs",
    "watchdog_test",
    "manual_override_test",
)
APPLIANCE_CHECKS = (
    "electrical_review",
    "live_test_acceptance",
    "detection_acceptance",
    "timing_acceptance",
    "appliance_ownership",
)


@dataclass(frozen=True)
class OperatorGrant:
    session_id: str
    operator: str
    mode: str
    expires_monotonic: float


class SafetyInterlock:
    def __init__(self, config: Phase5Config, mapper, session_id: str, grant=None):
        self.config, self.mapper, self.session_id, self.grant = config, mapper, session_id, grant
        self.config_hash = digest(config.path)
        self.base_hash = digest(config.path.parent / config.data["base_config"])

    def permits(self, appliance: dict, now: float, unix: float) -> tuple[bool, str]:
        cfg = self.config
        if cfg.mode == "OBSERVE":
            return False, "observe_never_commands"
        controller = next(c for c in cfg.data["controllers"] if c["id"] == appliance["controller"])
        if not controller["verified"] or not controller["evidence"].strip():
            return False, "firmware_protocol_unverified"
        if not cfg.relative(controller["evidence"]).is_file():
            return False, "firmware_evidence_missing"
        if cfg.mode == "DRY_RUN":
            return (
                (True, "firmware_isolated_dry_run")
                if controller["dry_run_enforced"]
                else (False, "firmware_dry_run_enforcement_unverified")
            )
        if not self.mapper.ready or not self.mapper.unchanged():
            return False, "physical_mapping_unverified_or_changed"
        if not appliance["ownership_verified"]:
            return False, "appliance_ownership_unverified"
        if cfg.mode == "LIVE_TEST" and not appliance["test_output_isolated"]:
            return False, "test_loads_not_physically_isolated"
        grant = self.grant
        if (
            grant is None
            or grant.session_id != self.session_id
            or grant.mode != cfg.mode
            or now >= grant.expires_monotonic
        ):
            return False, "explicit_session_operator_grant_required"
        if (
            digest(cfg.path) != self.config_hash
            or digest(cfg.path.parent / cfg.data["base_config"]) != self.base_hash
        ):
            return False, "configuration_changed"
        path = cfg.relative(cfg.data["authorization"])
        if path is None:
            return False, "authorization_evidence_pending"
        try:
            auth = json.loads(path.read_text(encoding="utf-8"))
            exact(
                auth,
                (
                    "schema_version",
                    "config_fingerprint",
                    "commissioning_sha256",
                    "mode",
                    "operators",
                    "expires_at",
                    "checks",
                    "firmware_checksums",
                ),
                "authorization",
            )
            if (
                auth["schema_version"] != 1
                or auth["mode"] != cfg.mode
                or auth["config_fingerprint"] != cfg.fingerprint
                or auth["commissioning_sha256"] != self.mapper.commissioning_hash
                or grant.operator not in auth["operators"]
                or auth["firmware_checksums"].get(controller["id"]) != controller["firmware_sha256"]
            ):
                return False, "authorization_binding_mismatch"
            expiry = datetime.fromisoformat(auth["expires_at"])
            if expiry.tzinfo is None or expiry.timestamp() <= unix:
                return False, "authorization_expired_or_undated"
            required = TEST_CHECKS + (APPLIANCE_CHECKS if cfg.mode == "LIVE_APPLIANCE" else ())
            for name in required:
                check = auth["checks"][name]
                exact(
                    check, ("verified", "reviewer", "verified_at", "evidence_file", "sha256"), name
                )
                reviewed = datetime.fromisoformat(check["verified_at"])
                evidence = (path.parent / check["evidence_file"]).resolve()
                if (
                    check["verified"] is not True
                    or not check["reviewer"].strip()
                    or reviewed.tzinfo is None
                    or reviewed.timestamp() > unix
                    or digest(evidence) != check["sha256"]
                ):
                    return False, "required_evidence_unverified:" + name
        except (ValueError, KeyError, TypeError, OSError):
            return False, "authorization_missing_or_malformed"
        return True, "operator_and_evidence_authorized"


def authorization_template(config: Phase5Config) -> dict:
    return {
        "schema_version": 1,
        "config_fingerprint": config.fingerprint,
        "commissioning_sha256": "PENDING",
        "mode": config.mode,
        "operators": [],
        "expires_at": None,
        "checks": {
            name: {
                "verified": False,
                "reviewer": "",
                "verified_at": None,
                "evidence_file": "",
                "sha256": "",
            }
            for name in TEST_CHECKS + APPLIANCE_CHECKS
        },
        "firmware_checksums": {c["id"]: c["firmware_sha256"] for c in config.data["controllers"]},
    }


def utc_now():
    return datetime.now(UTC).isoformat()
