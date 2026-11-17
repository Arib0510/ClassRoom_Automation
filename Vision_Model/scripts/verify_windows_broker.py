"""Verify the private Windows broker without dependencies or appliance commands."""

from __future__ import annotations

import json
import socket
import struct
import time
from pathlib import Path

BROKER = "10.247.68.155"
CREDENTIALS = Path(r"C:\ProgramData\ClassroomMQTT\client-credentials.txt")
ROOM = "ruet/classroom/reb_room_301"


def string(value: str) -> bytes:
    encoded = value.encode()
    return struct.pack("!H", len(encoded)) + encoded


def remaining_length(size: int) -> bytes:
    result = bytearray()
    while True:
        digit = size % 128
        size //= 128
        if size:
            digit |= 0x80
        result.append(digit)
        if not size:
            return bytes(result)


def packet(sock: socket.socket, header: int, body: bytes) -> None:
    sock.sendall(bytes((header,)) + remaining_length(len(body)) + body)


def receive(sock: socket.socket, timeout: float = 4.0) -> tuple[int, bytes] | None:
    sock.settimeout(timeout)
    try:
        first = sock.recv(1)
        if not first:
            return None
        multiplier, size = 1, 0
        while True:
            digit = sock.recv(1)
            if not digit:
                return None
            size += (digit[0] & 127) * multiplier
            if digit[0] & 128 == 0:
                break
            multiplier *= 128
        body = bytearray()
        while len(body) < size:
            chunk = sock.recv(size - len(body))
            if not chunk:
                return None
            body.extend(chunk)
        return first[0], bytes(body)
    except TimeoutError:
        return None


class Client:
    def __init__(
        self,
        client_id: str,
        user: str | None,
        password: str | None,
        will=None,
        expected_return_code: int = 0,
    ):
        self.sock = socket.create_connection((BROKER, 1883), timeout=4)
        flags = 0x02
        payload = string(client_id)
        if will:
            will_topic, will_payload = will
            flags |= 0x2E  # will retained, QoS 1, will flag, clean session
            payload += string(will_topic) + string(will_payload)
        if user is not None:
            flags |= 0x80
            payload += string(user)
        if password is not None:
            flags |= 0x40
            payload += string(password)
        body = string("MQTT") + bytes((4, flags)) + struct.pack("!H", 10) + payload
        packet(self.sock, 0x10, body)
        response = receive(self.sock)
        if response is None or response[0] >> 4 != 2:
            self.sock.close()
            raise RuntimeError("Broker did not return CONNACK")
        self.return_code = response[1][1]
        if self.return_code != expected_return_code:
            self.sock.close()
            raise RuntimeError(f"Unexpected broker CONNACK code {self.return_code}")

    def subscribe(self, topic: str, packet_id: int = 1) -> None:
        packet(self.sock, 0x82, struct.pack("!H", packet_id) + string(topic) + b"\x01")
        response = receive(self.sock)
        if response is None or response[0] >> 4 != 9 or response[1][2] == 0x80:
            raise RuntimeError("MQTT topic subscription was rejected")

    def publish(
        self,
        topic: str,
        value: str,
        qos: int = 0,
        packet_id: int = 1,
        retain: bool = False,
    ) -> None:
        body = string(topic)
        if qos:
            body += struct.pack("!H", packet_id)
        body += value.encode()
        packet(self.sock, 0x30 | (qos << 1) | int(retain), body)
        if qos:
            response = receive(self.sock)
            if response is None or response[0] >> 4 != 4:
                raise RuntimeError("Broker did not acknowledge an authorized publish")

    def next_publish(self, timeout: float = 4.0) -> tuple[str, str] | None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            response = receive(self.sock, max(0.05, deadline - time.monotonic()))
            if response is None:
                continue
            header, body = response
            packet_type = header >> 4
            if packet_type != 3 or len(body) < 2:
                continue
            topic_length = struct.unpack("!H", body[:2])[0]
            topic = body[2 : 2 + topic_length].decode()
            qos = (header >> 1) & 3
            offset = 2 + topic_length + (2 if qos else 0)
            if qos == 1:
                packet(self.sock, 0x40, body[2 + topic_length : offset])
            return topic, body[offset:].decode(errors="replace")
        return None

    def close(self, abrupt: bool = False) -> None:
        if not abrupt:
            try:
                packet(self.sock, 0xE0, b"")
            except OSError:
                pass
        self.sock.close()


def load_credentials() -> dict[str, str]:
    return dict(
        line.strip().split("=", 1)
        for line in CREDENTIALS.read_text(encoding="utf-8-sig").splitlines()
    )


def main() -> None:
    auth = load_credentials()
    anonymous = Client("migration-no-auth", None, None, expected_return_code=5)
    anonymous.close()
    print("Anonymous authentication rejection: PASS")

    app = Client("migration-app-check", "flutter-app", auth["flutter-app"])
    pi = Client("migration-pi-check", "pi-vision", auth["pi-vision"])
    topic = f"{ROOM}/vision/migration-check"
    app.subscribe(topic)
    pi.publish(topic, "ok", qos=1)
    if app.next_publish() != (topic, "ok"):
        raise RuntimeError("Authenticated Pi to Flutter delivery failed")
    pi.close()
    print("Authenticated publish and subscribe: PASS")

    controller = Client("migration-board-check", "esp32-board01", auth["esp32-board01"])
    query = f"{ROOM}/command/query"
    controller.subscribe(query)
    time.sleep(0.15)
    app.publish(query, "QUERY", qos=1)
    if controller.next_publish() != (query, "QUERY"):
        raise RuntimeError("Flutter to controller query delivery failed")
    print("Flutter to controller continuity while Pi is disconnected: PASS")

    availability = f"{ROOM}/vision/availability"
    retained_cleanup = Client("migration-lwt-cleanup", "pi-vision", auth["pi-vision"])
    retained_cleanup.publish(availability, "", qos=1, retain=True)
    retained_cleanup.close()
    app.subscribe(availability)
    time.sleep(0.15)
    will = Client(
        "migration-lwt-check",
        "pi-vision",
        auth["pi-vision"],
        (availability, json.dumps({"online": False})),
    )
    will.close(abrupt=True)
    if app.next_publish(timeout=5) != (availability, '{"online": false}'):
        raise RuntimeError("Broker did not publish Last Will after unexpected disconnect")
    print("Last Will and Testament: PASS")

    reconnected_pi = Client("migration-lwt-check", "pi-vision", auth["pi-vision"])
    reconnected_pi.publish(topic, "reconnected", qos=1)
    resumed = app.next_publish()
    if resumed != (topic, "reconnected"):
        raise RuntimeError(f"Authenticated reconnect delivery mismatch: {resumed!r}")
    reconnected_pi.publish(availability, "", qos=1, retain=True)
    print("Authenticated reconnect and publish recovery: PASS")

    observer = Client("migration-acl-observer", "pi-vision", auth["pi-vision"])
    forbidden = f"{ROOM}/zone/2/migration-check"
    observer.subscribe(forbidden)
    restricted = Client("migration-acl-check", "esp32-board01", auth["esp32-board01"])
    restricted.publish(forbidden, "probe")
    if observer.next_publish(timeout=1) is not None:
        raise RuntimeError("Broker allowed board 1 to publish in board 2's topic namespace")
    print("Per-controller ACL isolation: PASS")

    app.close()
    controller.close()
    observer.close()
    reconnected_pi.close()
    restricted.close(abrupt=True)


if __name__ == "__main__":
    main()
