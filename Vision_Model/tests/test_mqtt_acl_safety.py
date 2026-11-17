from __future__ import annotations

import re
from pathlib import Path


def test_pi_vision_acl_is_narrow_and_keeps_dry_run_diagnostics():
    path = Path(__file__).parents[2] / "Classroom/scripts/configure_windows_mosquitto.ps1"
    source = path.read_text()
    section = source.split('$aclLines.Add("user pi-vision")', 1)[1].split(
        '$aclLines.Add("user flutter-app")', 1
    )[0]
    rules = re.findall(r'\$aclLines\.Add\("([^"]+)"\)', section)
    assert rules
    assert "topic read ruet/classroom/reb_room_301/status/#" in rules
    assert "topic read classpulse/reb_room_301/app/requests" in rules
    assert "topic write classpulse/reb_room_301/app/state" in rules
    assert "topic write classpulse/reb_room_301/app/results" in rules
    assert "topic read classpulse/reb_room_301/controllers/+/status" in rules
    assert "topic read classpulse/reb_room_301/controllers/+/ack" in rules
    assert "topic write classpulse/reb_room_301/controllers/+/dry_run/command" in rules
    assert "topic readwrite classpulse/reb_room_301/diagnostics/non_actuating/#" in rules
    assert not any(rule.startswith("topic write ruet/") for rule in rules)
    assert not any(
        rule.startswith("topic write classpulse/reb_room_301/#")
        or rule.startswith("topic readwrite classpulse/reb_room_301/#")
        for rule in rules
    )
    assert not any(
        rule.endswith("/controllers/+/command") or rule.endswith("/controllers/+/command/#")
        for rule in rules
    )


def test_acl_hardening_backs_up_before_write_without_mqtt_publication():
    path = Path(__file__).parents[2] / "Classroom/scripts/harden_windows_mosquitto_acl.ps1"
    source = path.read_text()
    backup = source.index('Copy-Item -LiteralPath $aclPath -Destination $backup')
    write = source.index('[IO.File]::WriteAllLines($temporary, $updated')
    assert backup < write
    assert "mosquitto_pub" not in source
    assert ".publish(" not in source
