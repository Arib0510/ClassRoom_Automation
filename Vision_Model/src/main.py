"""CLI for static checks, synthetic simulation, real offline image inference and live capture."""

from __future__ import annotations

import argparse
import logging
import signal
import threading
import time
import uuid
from pathlib import Path

from .config import REPO_ROOT, load_config
from .detector import verify_model
from .mqtt_client import MQTTPublisher, build_payload, encode_json
from .occupancy import OccupancyTracker
from .zones import ZONE_IDS, ZoneMap

LOG = logging.getLogger(__name__)


def simulate(config) -> int:
    """Synthetic counts only. Does not open camera, interpreter, sockets or sleep."""
    tracker = OccupancyTracker(config.occupancy)
    boot_id = "simulation"
    for sequence in range(61):
        now = sequence * 0.5
        # First all zones empty, then two independently occupied, then all empty.
        counts = {
            key: int(key in ("front_left", "back_right") and 2 <= now < 8) for key in ZONE_IDS
        }
        tracker.update(counts, now)
        print(
            encode_json(
                build_payload(
                    device_id=config.device_id,
                    boot_id=boot_id,
                    sequence=sequence,
                    zones=tracker.snapshot(now),
                    now=now,
                    unix_time=1_700_000_000 + now,
                    last_observation=tracker.last_observation,
                    stale_seconds=config.occupancy.stale_seconds,
                    expiry_seconds=config.mqtt.expiry_seconds,
                )
            )
        )
    return 0


def run(config, zones: ZoneMap) -> int:
    from .camera import PiCamera
    from .detector import create_detector

    if not zones.calibrated:
        raise ValueError(
            "Live run requires calibrated:true in zones.yaml after on-site calibration"
        )
    if getattr(zones, "schema_version", None) != 2:
        raise ValueError(
            "Live run requires version-2 mounted-camera calibration; "
            "legacy polygons are previews only"
        )
    zones.validate_camera(config.camera)
    detector = create_detector(config.detector)
    tracker = OccupancyTracker(config.occupancy)
    boot_id = str(uuid.uuid4())
    publisher = MQTTPublisher(config.mqtt, config.device_id, boot_id)
    stop = threading.Event()
    previous_handlers = {}
    for sig in (signal.SIGINT, signal.SIGTERM):
        previous_handlers[sig] = signal.signal(sig, lambda signum, frame: stop.set())
    sequence = 0
    last_sent = float("-inf")
    previous_state = None

    def publish_current(force: bool = False) -> None:
        nonlocal sequence, last_sent, previous_state
        now = time.monotonic()
        snapshot = tracker.snapshot(now)
        # Counts are observation estimates; transmit promptly when count or stable state changes.
        current = tuple(
            (key, snapshot[key]["state"], snapshot[key]["person_count"]) for key in ZONE_IDS
        )
        if (
            force
            or publisher.needs_refresh
            or current != previous_state
            or now - last_sent >= config.mqtt.heartbeat_seconds
        ):
            payload = build_payload(
                device_id=config.device_id,
                boot_id=boot_id,
                sequence=sequence,
                zones=snapshot,
                now=now,
                unix_time=time.time(),
                last_observation=tracker.last_observation,
                stale_seconds=config.occupancy.stale_seconds,
                expiry_seconds=config.mqtt.expiry_seconds,
            )
            sequence += 1
            if publisher.publish(payload):
                previous_state = current
                last_sent = now

    try:
        publisher.start()
        publish_current(force=True)
        with PiCamera(config.camera) as camera:
            while not stop.is_set():
                cycle_start = time.monotonic()
                frame = camera.capture()
                detections = detector.detect(frame.rgb)
                if time.monotonic() - frame.captured_at > config.occupancy.stale_seconds:
                    raise RuntimeError("Observation expired before inference completed")
                update_zone_observation(
                    tracker,
                    zones,
                    [d.box for d in detections],
                    frame.captured_at,
                    (frame.rgb.shape[1], frame.rgb.shape[0]),
                )
                publish_current()
                stop.wait(max(0.0, config.poll_seconds - (time.monotonic() - cycle_start)))
        return 0
    except Exception:
        LOG.exception("Vision fault; invalidating all quadrants")
        return 1
    finally:
        # Never send a final vacant state. Controllers handle unknown / offline / expired.
        tracker.invalidate()
        try:
            publish_current(force=True)
        finally:
            publisher.close()
            for sig, handler in previous_handlers.items():
                signal.signal(sig, handler)


def update_zone_observation(tracker, zones, boxes, captured_at, frame_size):
    """Unlocatable people invalidate the observation; they must not become vacant counts."""
    if getattr(zones, "schema_version", None) == 2:
        observation = zones.observe(boxes, frame_size=frame_size)
        if observation.counts is None:
            tracker.invalidate()
            return
        counts = observation.counts
    else:
        counts = zones.count(boxes)
    tracker.update(counts, captured_at)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check-config", "simulate", "infer-images", "run"))
    parser.add_argument("--config", type=Path, default=REPO_ROOT / "config/config.yaml")
    parser.add_argument("--input", type=Path, help="Image folder for infer-images (not recursive)")
    parser.add_argument("--output", type=Path, help="New or empty output folder for infer-images")
    parser.add_argument(
        "--runtime",
        choices=("auto", "tensorflow", "tflite-runtime"),
        help="Offline interpreter; auto chooses TensorFlow on Windows",
    )
    parser.add_argument(
        "--overlay-zones", action="store_true", help="Draw UNCALIBRATED zone polygons"
    )
    args = parser.parse_args(argv)
    if args.command == "infer-images":
        if args.input is None or args.output is None:
            parser.error("infer-images requires both --input and --output")
    elif args.input is not None or args.output is not None or args.runtime or args.overlay_zones:
        parser.error("--input, --output, --runtime and --overlay-zones apply only to infer-images")
    try:
        config = load_config(args.config)
        logging.basicConfig(
            level=config.log_level, format="%(asctime)s %(levelname)s %(name)s: %(message)s"
        )
        if args.command == "infer-images":
            from .image_inference import infer_images

            summary = infer_images(
                config,
                args.input,
                args.output,
                backend=args.runtime or "auto",
                overlay_zones=args.overlay_zones,
            )
            print(encode_json(summary))
            return 0 if summary["status"] == "completed" else 2
        zones = ZoneMap.load(config.zones_path)
        if args.command == "check-config":
            verify_model(config.detector)
            print("Configuration, four polygons, person label, and model SHA256 are valid.")
            print(
                "Physical zone calibration: "
                + ("declared complete" if zones.calibrated else "PENDING")
            )
            print("No camera, interpreter, broker, or hardware accessed.")
            return 0
        if args.command == "simulate":
            return simulate(config)
        return run(config, zones)
    except (OSError, ValueError, RuntimeError) as exc:
        LOG.error("%s", exc)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
