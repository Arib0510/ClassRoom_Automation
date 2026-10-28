"""Isolated Phase 5 service and Windows replay CLI. Legacy src.main remains unchanged."""

from __future__ import annotations

import argparse
import json
import platform
import signal
import struct
import subprocess
import time
import uuid
from pathlib import Path

import numpy as np

from .detector import Detection, verify_model
from .phase5_config import load_phase5
from .phase5_control import ApplianceEngine
from .phase5_metrics import EventLog, resources, summarize
from .phase5_mqtt import MemoryTransport, MQTTTransport
from .phase5_occupancy import (
    PhysicalMapper,
    TemporalOccupancy,
    ZoneEvidence,
    commissioning_template,
    unknown,
)
from .phase5_safety import OperatorGrant, SafetyInterlock, authorization_template


class Pipeline:
    """One shared controller for live frames, cached predictions and synthetic replay."""

    def __init__(
        self,
        config,
        transport,
        session_id,
        mapper=None,
        interlock=None,
        log=None,
        clock_valid=False,
        grant=None,
    ):
        self.config, self.transport, self.session_id, self.log = config, transport, session_id, log
        self.mapper = mapper or PhysicalMapper(config)
        self.temporal = TemporalOccupancy(config.base.occupancy)
        self.interlock = interlock or SafetyInterlock(config, self.mapper, session_id, grant)
        self.engine = ApplianceEngine(
            config, transport, self.interlock, session_id, clock_valid=clock_valid
        )
        self.last_telemetry = -float("inf")
        self.frames = 0
        self.arrivals = {}

    def mark_arrival(self, trial_id, zone, now):
        if (
            zone not in self.temporal.zones
            or not trial_id
            or trial_id in self.arrivals
            or len(self.arrivals) >= 32
        ):
            raise ValueError(
                "Arrival marker needs a new ID, known zone and bounded trial inventory"
            )
        self.arrivals[trial_id] = (zone, now)
        self.record(
            "operator_arrival_marker",
            trial_id=trial_id,
            zone=zone,
            now=now,
            limitation="Operator reaction marker; independent external observation still required",
        )

    def record(self, event, **fields):
        if self.log:
            self.log.write(event, **fields)

    def tick(self, now, unix):
        snapshot = self.temporal.snapshot(now)
        decisions = self.engine.step(snapshot, now, unix)
        for trial_id, (zone, started) in list(self.arrivals.items()):
            if snapshot[zone]["state"] == "OCCUPIED":
                self.record(
                    "arrival_decision",
                    trial_id=trial_id,
                    zone=zone,
                    arrival_to_decision_seconds=now - started,
                    measurement_method="same-device operator marker; not physical activation",
                )
                del self.arrivals[trial_id]
            elif now - started > 60:
                self.record(
                    "arrival_incomplete",
                    trial_id=trial_id,
                    zone=zone,
                    arrival_to_decision_seconds=None,
                )
                del self.arrivals[trial_id]
        for event in self.engine.events:
            self.record(event["event"], **{k: v for k, v in event.items() if k != "event"})
        self.engine.events.clear()
        if (
            self.transport.connected
            and now - self.last_telemetry >= self.config.base.mqtt.heartbeat_seconds
        ):
            packet = {
                "schema_version": 1,
                "kind": "phase5_telemetry",
                "session_id": self.session_id,
                "mode": self.config.mode,
                "sent_at_unix_ms": int(unix * 1000),
                "expires_at_unix_ms": int((unix + self.config.base.occupancy.stale_seconds) * 1000),
                "zones": snapshot,
                "appliances": decisions,
                "physical_mapping_verified": self.mapper.ready,
            }
            if self.transport.publish(self.config.data["mqtt"]["prefix"] + "/telemetry", packet):
                self.last_telemetry = now
        return snapshot, decisions

    def observe(self, frame, result, now, unix):
        age = now - frame["captured_at"]
        start = time.monotonic()
        if (
            age < 0
            or age >= self.config.base.occupancy.stale_seconds
            or result.get("frame_id") != frame["frame_id"]
        ):
            self.fault("stale_or_mismatched_frame", now, unix)
            return self.tick(now, unix)
        rgb = frame["rgb"]
        usable = (
            rgb.dtype == np.uint8
            and rgb.ndim == 3
            and rgb.shape[2] == 3
            and max(np.std(rgb, axis=(0, 1))) > 1
        )
        evidence = self.mapper.map(
            result["detections"], (rgb.shape[1], rgb.shape[0]), image_usable=usable
        )
        mapping_time = time.monotonic() - start
        decision_now, decision_unix = now + mapping_time, unix + mapping_time
        if age + mapping_time >= self.config.data["resources"]["max_pipeline_seconds"]:
            self.fault("pipeline_budget_exceeded_before_decision", decision_now, decision_unix)
            raise TimeoutError("Frame processing budget exceeded before control decisions")
        self.temporal.update(frame["frame_id"], frame["captured_at"], evidence, decision_now)
        self.frames += 1
        outcome = self.tick(decision_now, decision_unix)
        self.record(
            "vision_frame",
            phase="cold_start" if self.frames == 1 else "sustained",
            frame_id=frame["frame_id"],
            capture_duration_seconds=frame.get("capture_duration_seconds"),
            frame_age_seconds=age,
            frame_age_at_inference_start_seconds=frame.get("age_at_inference_start_seconds"),
            zone_mapping_seconds=mapping_time,
            pipeline_seconds=age + time.monotonic() - start,
            passes=result["passes"],
            timings=result["timings"],
            strategy=result["strategy"],
            detections=result.get("records", []),
            raw_evidence={z: vars(e) for z, e in evidence.items()},
            superseded_frames_estimate=frame.get("superseded_frames_estimate"),
        )
        return outcome

    def fault(self, reason, now, unix):
        self.temporal.invalidate(reason)
        self.record("pipeline_fault", reason=reason)
        return self.tick(now, unix)


def unix_synchronized():
    try:
        check = subprocess.run(
            ["timedatectl", "show", "-p", "NTPSynchronized", "--value"],
            capture_output=True,
            text=True,
            timeout=2,
        )
        return check.returncode == 0 and check.stdout.strip() == "yes"
    except (OSError, subprocess.TimeoutExpired):
        return False


def replay(config, cache_path, output, *, synthetic=False):
    if config.mode != "OBSERVE" or config.data["mqtt"]["enabled"]:
        raise ValueError("Offline replay requires OBSERVE with MQTT disabled; no live transport")
    from .person_labels import source_hash

    output = Path(output)
    output.mkdir(parents=True, exist_ok=False)
    session = "offline-replay"
    pipeline = Pipeline(config, MemoryTransport(), session)
    document = json.loads(Path(cache_path).read_text(encoding="utf-8"))
    results = []
    if synthetic:
        if document.get("source") != "synthetic":
            raise ValueError("Synthetic replay needs explicit source: synthetic")
        for i, event in enumerate(document["events"]):
            now = event["time"]
            if "fault" in event:
                snapshot, decisions = pipeline.fault(event["fault"], now, 1_800_000_000 + now)
            else:
                if set(event["zones"]) != set(pipeline.temporal.zones):
                    raise ValueError("Synthetic events require all zones")
                evidence = {
                    z: ZoneEvidence(
                        s,
                        1 if s == "OCCUPIED" else (0 if s == "VACANT" else None),
                        None,
                        "synthetic_fixture",
                    )
                    for z, s in event["zones"].items()
                }
                pipeline.temporal.update(f"synthetic-{i}", now, evidence, now)
                snapshot, decisions = pipeline.tick(now, 1_800_000_000 + now)
            results.append({"time": now, "zones": snapshot, "appliances": decisions})
    else:
        if (
            document.get("status") != "completed"
            or document.get("model_sha256") != config.base.detector.sha256
        ):
            raise ValueError("Replay requires completed verified SSD prediction cache")
        from .phase3_diagnostics import select_predictions

        mode = (
            "full"
            if config.data["strategy"]["mode"] == "single_pass"
            else config.data["strategy"]["mode"]
        )
        for i, info in enumerate(document["images"]):
            now = float(i)
            # Photos have no temporal arrival/continuous mounted-view semantics. Reset each image.
            pipeline.temporal.invalidate("independent_historical_photo")
            rows, _ = select_predictions(
                info["modes"][mode]["person_outputs"],
                mode,
                config.base.detector.confidence_threshold,
                config.data["strategy"]["nms_iou"],
            )
            boxes = [
                Detection(
                    tuple(r[f"{k}_normalized"] for k in ("ymin", "xmin", "ymax", "xmax")),
                    r["confidence"],
                    r["class_id"],
                )
                for r in rows
            ]
            evidence = unknown("historical_photos_not_bound_to_mounted_camera")
            pipeline.temporal.update(info["file_name"], now, evidence, now)
            snapshot, decisions = pipeline.tick(now, 1_800_000_000 + now)
            results.append(
                {
                    "file_name": info["file_name"],
                    "cached_person_predictions": len(boxes),
                    "zones": snapshot,
                    "appliances": decisions,
                }
            )
    result = {
        "source": "synthetic" if synthetic else "historical_ssd_cache",
        "hardware_tested": False,
        "input_sha256": source_hash(Path(cache_path)),
        "mqtt_used": False,
        "results": results,
    }
    (output / "replay.json").write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
    return result


def run_service(
    config,
    output,
    *,
    input_folder=None,
    backend="tflite-runtime",
    max_frames=0,
    arm_operator=None,
    override_path=None,
    arm_seconds=300,
):
    from .images import ImageFolder
    from .phase5_capture import ImageSource
    from .phase5_workers import BoundedWorker

    if input_folder is not None and config.mode != "OBSERVE":
        raise ValueError("Offline image runs require OBSERVE; photos cannot authorize actuators")
    if config.mode.startswith("LIVE") and not arm_operator:
        raise ValueError(
            "Live modes require a named operator and session arming before hardware/network startup"
        )
    is_target = (
        platform.system() == "Linux"
        and struct.calcsize("P") == 4
        and platform.machine() in ("armv7l", "armv8l")
    )
    if input_folder is None and not is_target:
        raise ValueError("Camera service requires the actual Linux ARMv7 32-bit target")
    mapper = PhysicalMapper(config)  # Validate BEFORE camera/MQTT access.
    verify_model(config.base.detector)
    session_id = uuid.uuid4().hex
    grant = None
    if arm_operator:
        if (
            not config.mode.startswith("LIVE")
            or not arm_operator.strip()
            or not 1 <= arm_seconds <= 600
        ):
            raise ValueError("Named live-mode operator and 1..600 second arming duration required")
        phrase = f"ARM {config.mode} {session_id}"
        if input(f"Physical evidence checks still apply. Type {phrase}: ") != phrase:
            raise ValueError("Session arming phrase did not match")
        grant = OperatorGrant(session_id, arm_operator, config.mode, time.monotonic() + arm_seconds)
    provenance = (
        "pi_saved_image_pipeline"
        if is_target
        else (
            "windows_offline_image_inference"
            if platform.system() == "Windows"
            else "host_saved_image_pipeline"
        )
    )
    if input_folder is None:
        provenance = "pi_hardware_runtime"
    log = EventLog(output, config.data["logging"], provenance)
    transport = (
        MQTTTransport(config, session_id) if config.data["mqtt"]["enabled"] else MemoryTransport()
    )
    pipeline = Pipeline(
        config,
        transport,
        session_id,
        mapper=mapper,
        log=log,
        clock_valid=unix_synchronized() if input_folder is None else False,
        grant=grant,
    )
    stopping = False
    old_handlers = {}
    seen_requests = set()

    def stop(signum, frame):
        nonlocal stopping
        stopping = True

    def tick():
        if stopping:
            raise KeyboardInterrupt
        now, unix = time.monotonic(), time.time()
        pipeline.tick(now, unix)
        if override_path and Path(override_path).exists():
            raw = Path(override_path).read_bytes()
            if len(raw) > 16_384:
                raise ValueError("Override file exceeds bound")
            try:
                request = json.loads(raw)
            except ValueError:
                return
            if request["session_id"] != session_id:
                raise ValueError("Override must target current session")
            if len(request["requests"]) > 16:
                raise ValueError("At most sixteen local requests per file")
            for item in request["requests"]:
                if item["request_id"] in seen_requests:
                    continue
                if len(seen_requests) >= 128:
                    raise ValueError("Operator request bound reached; start a reviewed new session")
                remaining = item["expires_at_unix_ms"] / 1000 - unix
                if not 0 < remaining <= 300:
                    continue
                if item["action"] == "arrival":
                    marker = item["at_monotonic"]
                    if not 0 <= now - marker <= 2:
                        raise ValueError(
                            "Arrival marker must use this Pi monotonic clock within two seconds"
                        )
                    pipeline.mark_arrival(item["request_id"], item["zone"], marker)
                elif item["action"] == "clear_fault":
                    pipeline.engine.clear_fault(item["appliance_id"], item["operator"])
                elif item["action"] == "override":
                    pipeline.engine.override(
                        item["appliance_id"], item["state"], item["operator"], now + remaining, now
                    )
                else:
                    raise ValueError("Unknown operator action")
                seen_requests.add(item["request_id"])

    camera = detector = None
    exit_code = 0
    try:
        for sig in (signal.SIGINT, signal.SIGTERM):
            old_handlers[sig] = signal.signal(sig, stop)
        if isinstance(transport, MQTTTransport):
            transport.start()
        log.write(
            "startup",
            session_id=session_id,
            mode=config.mode,
            config_fingerprint=config.fingerprint,
            model_sha256=config.base.detector.sha256,
            clock_synchronized=pipeline.engine.clock_valid,
            physical_mapping_verified=mapper.ready,
        )
        if input_folder:
            camera = ImageSource(ImageFolder(Path(input_folder)).discover())
        else:
            startup = time.perf_counter()
            camera = BoundedWorker("camera", config.path)
            camera.wait_ready(config.data["resources"]["startup_timeout_seconds"], tick)
            log.write(
                "camera_ready",
                phase="cold_start",
                timings={"camera_worker_startup_seconds": time.perf_counter() - startup},
            )
        startup = time.perf_counter()
        detector = BoundedWorker("detector", config.path, backend)
        detector.wait_ready(config.data["resources"]["startup_timeout_seconds"], tick)
        log.write(
            "detector_ready",
            phase="cold_start",
            timings={"detector_worker_startup_seconds": time.perf_counter() - startup},
        )
        failures = 0
        started, previous_resource = time.monotonic(), None
        while not stopping and (max_frames == 0 or pipeline.frames < max_frames):
            cycle = time.monotonic()
            try:
                frame = (
                    camera.capture()
                    if input_folder
                    else camera.call(None, config.base.camera.timeout_seconds + 0.25, tick)
                )
            except StopIteration:
                break
            except (RuntimeError, TimeoutError, OSError) as exc:
                pipeline.fault("camera_failure:" + str(exc), time.monotonic(), time.time())
                failures += 1
                if input_folder or failures > config.data["camera"]["restart_attempts"]:
                    raise
                camera.close()
                # Bounded reinitializations while the control heartbeat remains responsive.
                until = time.monotonic() + min(4, 2 ** (failures - 1))
                while time.monotonic() < until:
                    tick()
                    time.sleep(0.05)
                camera = BoundedWorker("camera", config.path)
                camera.wait_ready(config.data["resources"]["startup_timeout_seconds"], tick)
                continue
            if time.monotonic() - frame["captured_at"] >= config.base.occupancy.stale_seconds:
                pipeline.fault("frame_stale_before_inference", time.monotonic(), time.time())
                continue
            try:
                frame["age_at_inference_start_seconds"] = time.monotonic() - frame["captured_at"]
                result = detector.call(
                    frame, config.data["resources"]["inference_timeout_seconds"], tick
                )
            except (RuntimeError, TimeoutError, OSError) as exc:
                pipeline.fault(
                    "detector_failure_or_timeout:" + str(exc), time.monotonic(), time.time()
                )
                raise
            now = time.monotonic()
            pids = [detector.process.pid] + ([] if input_folder else [camera.process.pid])
            usage = resources(pids)
            if previous_resource and usage.get("process_tree_cpu_seconds") is not None:
                prior_time, prior_cpu = previous_resource
                usage["cpu_utilization_percent"] = max(
                    0, 100 * (usage["process_tree_cpu_seconds"] - prior_cpu) / (now - prior_time)
                )
            if usage.get("process_tree_cpu_seconds") is not None:
                previous_resource = (now, usage["process_tree_cpu_seconds"])
            limits = config.data["resources"]
            over = (
                now - frame["captured_at"] > limits["max_pipeline_seconds"]
                or input_folder is None
                and usage["total_rss_mb"] is None
                or usage["total_rss_mb"] is not None
                and usage["total_rss_mb"] > limits["max_total_rss_mb"]
                or usage["available_mb"] is not None
                and usage["available_mb"] < limits["min_available_mb"]
            )
            if over:
                pipeline.fault("resource_or_pipeline_budget_exceeded", now, time.time())
                log.write("resource_limit", strategy=config.data["strategy"]["mode"], **usage)
                raise RuntimeError(
                    "Selected strategy disabled after resource/deadline breach; "
                    "no automatic strategy substitution"
                )
            pipeline.observe(frame, result, now, time.time())
            log.write(
                "resources",
                frames=pipeline.frames,
                frames_per_second=pipeline.frames / (time.monotonic() - started),
                **usage,
            )
            while not stopping and time.monotonic() - cycle < config.base.poll_seconds:
                tick()
                time.sleep(0.02)
    except KeyboardInterrupt:
        pass
    except Exception as exc:
        exit_code = 1
        pipeline.temporal.invalidate("fatal")
        log.write("fatal", error=f"{type(exc).__name__}: {exc}")
    finally:
        pipeline.temporal.invalidate("shutdown")
        operations = [lambda: pipeline.tick(time.monotonic(), time.time())]
        operations += [
            resource.close for resource in (camera, detector, transport) if resource is not None
        ]
        for operation in operations:
            try:
                operation()
            except Exception as exc:
                exit_code = 1
                log.write("cleanup_error", error=f"{type(exc).__name__}:{exc}")
        try:
            log.write(
                "shutdown",
                frames=pipeline.frames,
                exit_code=exit_code,
                counters=pipeline.engine.counters,
                physical_outputs_confirmed=False,
            )
        finally:
            log.close()
            for sig, handler in old_handlers.items():
                signal.signal(sig, handler)
    return exit_code


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=(
            "check",
            "run",
            "replay",
            "summarize",
            "authorization-template",
            "request",
            "commissioning-template",
        ),
    )
    parser.add_argument("--config", type=Path, default=Path("config/phase5.example.yaml"))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--input", type=Path)
    parser.add_argument(
        "--backend", choices=("tflite-runtime", "tensorflow"), default="tflite-runtime"
    )
    parser.add_argument("--synthetic", action="store_true")
    parser.add_argument("--max-frames", type=int, default=0)
    parser.add_argument("--arm-operator")
    parser.add_argument("--arm-seconds", type=int, default=300)
    parser.add_argument("--override-file", type=Path)
    parser.add_argument("--session")
    parser.add_argument("--operator")
    parser.add_argument("--action", choices=("arrival", "override", "clear_fault"))
    parser.add_argument("--zone", choices=("front_left", "front_right", "back_left", "back_right"))
    parser.add_argument("--appliance")
    parser.add_argument("--state", choices=("ON", "OFF", "AUTO"))
    args = parser.parse_args(argv)
    try:
        cfg = load_phase5(args.config)
        if args.command == "check":
            verify_model(cfg.base.detector)
            mapper = PhysicalMapper(cfg)
            print(
                json.dumps(
                    {
                        "software_config_valid": True,
                        "mode": cfg.mode,
                        "fingerprint": cfg.fingerprint,
                        "physical_mapping_verified": mapper.ready,
                        "firmware_controllers": len(cfg.data["controllers"]),
                        "hardware_acceptance": "PENDING",
                    }
                )
            )
        elif args.command == "run":
            if args.output is None or args.max_frames < 0:
                raise ValueError("run needs a NEW output directory and nonnegative max-frames")
            if args.input is None:
                import platform
                import struct

                if (
                    platform.system() != "Linux"
                    or struct.calcsize("P") != 4
                    or platform.machine() not in ("armv7l", "armv8l")
                ):
                    raise ValueError(
                        "Camera run targets Linux ARMv7 32-bit; use --input on Windows"
                    )
            return run_service(
                cfg,
                args.output,
                input_folder=args.input,
                backend=args.backend,
                max_frames=args.max_frames,
                arm_operator=args.arm_operator,
                override_path=args.override_file,
                arm_seconds=args.arm_seconds,
            )
        elif args.command == "replay":
            if args.input is None or args.output is None:
                raise ValueError("replay needs --input and NEW --output")
            result = replay(cfg, args.input, args.output, synthetic=args.synthetic)
            print(
                json.dumps(
                    {
                        "source": result["source"],
                        "events": len(result["results"]),
                        "hardware_tested": False,
                    }
                )
            )
        elif args.command == "request":
            if (
                args.output is None
                or args.output.exists()
                or not args.session
                or not args.operator
                or not args.action
                or args.action == "arrival"
                and not args.zone
                or args.action in ("override", "clear_fault")
                and not args.appliance
                or args.action == "override"
                and args.state is None
            ):
                raise ValueError("New request file, session, operator and action fields required")
            item = {
                "request_id": uuid.uuid4().hex,
                "action": args.action,
                "operator": args.operator,
                "expires_at_unix_ms": int((time.time() + 30) * 1000),
                "at_monotonic": time.monotonic(),
                "zone": args.zone,
                "appliance_id": args.appliance,
                "state": args.state,
            }
            args.output.parent.mkdir(parents=True, exist_ok=True)
            with args.output.open("x", encoding="utf-8") as handle:
                json.dump({"session_id": args.session, "requests": [item]}, handle)
        else:
            if args.output is None or args.output.exists():
                raise ValueError("Choose a new output file")
            if args.command == "summarize":
                result = summarize(args.input)
            elif args.command == "commissioning-template":
                if args.input is None:
                    raise ValueError("commissioning-template needs --input geometry")
                result = commissioning_template(cfg, args.input)
            else:
                result = authorization_template(cfg)
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
        return 0
    except (OSError, ValueError, RuntimeError) as exc:
        parser.exit(1, f"Phase 5: {exc}\n")


if __name__ == "__main__":
    raise SystemExit(main())
