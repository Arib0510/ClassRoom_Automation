import json
from dataclasses import replace
from types import SimpleNamespace

import pytest

from src.config import MQTTConfig, OccupancyConfig
from src.mqtt_client import MQTTPublisher, build_payload, encode_json
from src.occupancy import OccupancyTracker
from src.zones import ZONE_IDS


def payload(now=1.0, last_observation=0.6, **overrides):
    tracker = OccupancyTracker(OccupancyConfig())
    tracker.update({key: int(key == "front_left") for key in ZONE_IDS}, 0)
    tracker.update({key: int(key == "front_left") for key in ZONE_IDS}, 0.6)
    values = dict(
        device_id="pi-01",
        boot_id="boot-01",
        sequence=7,
        zones=tracker.snapshot(now),
        now=now,
        unix_time=1_700_000_000 + now,
        last_observation=last_observation,
        stale_seconds=4,
        expiry_seconds=8,
    )
    return build_payload(**(values | overrides))


def test_payload_contract_and_freshness_lease():
    result = json.loads(encode_json(payload()))
    assert result["schema_version"] == 1
    assert result["device_id"] == "pi-01"
    assert result["boot_id"] == "boot-01" and result["sequence"] == 7
    assert result["observation_age_ms"] == 400
    assert result["expires_at_unix_ms"] - result["sent_at_unix_ms"] == 3600
    assert set(result["zones"]) == set(ZONE_IDS)
    assert result["zones"]["front_left"]["state"] == "occupied"
    assert result["zones"]["front_right"]["state"] == "unknown"
    assert result["sent_at"].endswith("+00:00")


def test_missing_or_expired_observation_cannot_publish_occupied():
    for last in (None, -10):
        result = payload(last_observation=last)
        assert all(
            z["state"] == "unknown" and z["person_count"] is None for z in result["zones"].values()
        )


@pytest.mark.parametrize(
    "change",
    [
        dict(sequence=-1),
        dict(sequence=True),
        dict(zones={}),
        dict(last_observation=2),
        dict(unix_time=float("nan")),
    ],
)
def test_invalid_payload_rejected(change):
    with pytest.raises(ValueError):
        payload(**change)


def test_nonfinite_json_never_serialized():
    with pytest.raises(ValueError):
        encode_json({"bad": float("nan")})


class FakeClient:
    def __init__(self):
        self.calls = []
        self.sent = True
        self.rc = 0

    def __getattr__(self, name):
        def record(*args, **kwargs):
            self.calls.append((name, args, kwargs))

        return record

    def publish(self, topic, data, **kwargs):
        self.calls.append(("publish", (topic, data), kwargs))
        return SimpleNamespace(
            rc=self.rc, is_published=lambda: self.sent, wait_for_publish=lambda **kwargs: None
        )


@pytest.fixture
def publisher(monkeypatch):
    monkeypatch.delenv("CLASSROOM_MQTT_USERNAME", raising=False)
    monkeypatch.delenv("CLASSROOM_MQTT_PASSWORD", raising=False)
    fake = FakeClient()
    return MQTTPublisher(MQTTConfig(), "pi-01", "boot-01", client=fake), fake


def test_offline_drop_reconnect_refresh_and_nonretained_telemetry(publisher):
    publisher, fake = publisher
    assert not publisher.publish(payload())
    assert not any(c[0] == "publish" for c in fake.calls)
    publisher._on_connect(fake, None, None, 0, None)
    assert publisher.needs_refresh
    assert publisher.publish(payload())
    assert not publisher.needs_refresh
    topic, data = fake.calls[-1][1]
    assert topic.endswith("/state")
    assert json.loads(data)["sequence"] == 7
    assert fake.calls[-1][2] == dict(qos=0, retain=False)
    publisher._on_disconnect(fake, None, None, 1, None)
    assert not publisher.publish(payload())


def test_will_and_graceful_offline_are_retained_with_boot_id(publisher):
    publisher, fake = publisher
    will = next(call for call in fake.calls if call[0] == "will_set")
    assert will[2] == dict(qos=1, retain=True)
    assert json.loads(will[1][1])["online"] is False
    publisher.start()
    publisher._on_connect(fake, None, None, 0, None)
    publisher.close()
    offline = [c for c in fake.calls if c[0] == "publish"][-1]
    assert offline[1][0].endswith("/availability")
    assert json.loads(offline[1][1]) == dict(
        schema_version=1, device_id="pi-01", boot_id="boot-01", online=False
    )


def test_unsent_telemetry_is_bounded_and_recovers_after_reconnect(publisher):
    publisher, fake = publisher
    publisher._on_connect(fake, None, None, 0, None)
    fake.sent = False
    assert publisher.publish(payload())
    before = len(fake.calls)
    assert not publisher.publish(payload(sequence=8))
    assert len(fake.calls) == before
    publisher._on_disconnect(fake, None, None, 1, None)
    publisher._on_connect(fake, None, None, 0, None)
    assert publisher.publish(payload(sequence=9))


def test_authentication_tls_and_failed_publish(monkeypatch):
    monkeypatch.setenv("CLASSROOM_MQTT_USERNAME", "sensor")
    monkeypatch.setenv("CLASSROOM_MQTT_PASSWORD", "example")
    fake = FakeClient()
    publisher = MQTTPublisher(replace(MQTTConfig(), tls=True), "pi", "boot", client=fake)
    assert any(c[0] == "username_pw_set" and c[1] == ("sensor", "example") for c in fake.calls)
    assert any(c[0] == "tls_set" for c in fake.calls)
    publisher._on_connect(fake, None, None, 0, None)
    fake.rc = 4
    assert not publisher.publish(payload())
    monkeypatch.delenv("CLASSROOM_MQTT_USERNAME")
    with pytest.raises(ValueError, match="without a username"):
        MQTTPublisher(MQTTConfig(), "pi", "boot", client=FakeClient())


def test_rejected_connection_does_not_publish(publisher):
    publisher, fake = publisher
    publisher._on_connect(fake, None, None, 5, None)
    assert not publisher.publish(payload())
