"""One in-flight RPC per worker. Parent can service control/watchdogs while native code stalls."""

from __future__ import annotations

import multiprocessing as mp
import queue
import threading
import time


def worker_main(connection, kind, config_path, backend):
    resource = None
    try:
        from .phase5_config import load_phase5

        config = load_phase5(config_path)
        if kind == "camera":
            from .phase5_capture import CaptureSource

            resource = CaptureSource(config).open()

            def function(data):
                return resource.capture()
        else:
            from .detector import create_detector
            from .phase5_vision import StrategyDetector

            resource = create_detector(config.base.detector, backend=backend)
            detector = StrategyDetector(resource, config.data["strategy"])
            function = detector.detect
        connection.send(("ready", {"kind": kind}))
        while True:
            message = connection.recv()
            if message is None:
                break
            request_id, data = message
            try:
                result = function(data)
                connection.send((request_id, result))
            except Exception as exc:
                connection.send(("error", f"{type(exc).__name__}: {exc}"))
                break
    except (Exception, KeyboardInterrupt) as exc:
        try:
            connection.send(("error", f"{type(exc).__name__}: {exc}"))
        except (OSError, EOFError):
            pass
    finally:
        if resource is not None and hasattr(resource, "close"):
            resource.close()
        connection.close()


class BoundedWorker:
    def __init__(self, kind, config_path, backend="tflite-runtime", context=None):
        self.context = context or mp.get_context("spawn")
        self.parent, child = self.context.Pipe()
        self.process = self.context.Process(
            target=worker_main, args=(child, kind, str(config_path), backend), daemon=True
        )
        self.process.start()
        child.close()
        self.busy = False
        self.sequence = 0
        self.ready = False

    def wait_ready(self, timeout, tick=lambda: None):
        started = time.monotonic()
        while time.monotonic() - started < timeout:
            tick()
            if self.parent.poll(0.05):
                kind, result = self.parent.recv()
                if kind != "ready":
                    raise RuntimeError(result)
                self.ready = True
                return
            if not self.process.is_alive():
                raise RuntimeError("Worker exited during startup")
        self.close()
        raise TimeoutError("Worker startup timeout")

    def call(self, data, timeout, tick=lambda: None):
        if self.busy or not self.ready:
            raise RuntimeError("Worker allows exactly one ready/in-flight request")
        self.busy = True
        self.sequence += 1
        started = time.monotonic()
        completed = queue.Queue(maxsize=1)

        def exchange():
            try:
                self.parent.send((self.sequence, data))
                completed.put((True, self.parent.recv()))
            except (OSError, EOFError) as exc:
                completed.put((False, str(exc)))

        # Only one bounded IPC thread; it also protects the parent from a blocked pipe send/recv.
        thread = threading.Thread(target=exchange, daemon=True)
        thread.start()
        try:
            while time.monotonic() - started < timeout:
                tick()
                try:
                    ok, value = completed.get(timeout=0.05)
                except queue.Empty:
                    continue
                if ok:
                    sequence, result = value
                    if sequence != self.sequence:
                        raise RuntimeError(f"Worker error or request mismatch: {result}")
                    return result
                raise RuntimeError(f"Worker IPC failed: {value}")
            self.close()
            raise TimeoutError("Native worker deadline exceeded")
        finally:
            thread.join(timeout=0.1)
            if thread.is_alive():
                self.close()
            thread.join(timeout=1)
            self.busy = False
            if thread.is_alive():
                raise RuntimeError(
                    "IPC thread failed to stop; do not restart worker in this process"
                )

    def close(self):
        if self.process.is_alive():
            try:
                if not self.busy:
                    self.parent.send(None)
            except (BrokenPipeError, OSError):
                pass
            self.process.join(timeout=0.5)
            if self.process.is_alive():
                self.process.terminate()
                self.process.join(timeout=1)
            if self.process.is_alive():
                self.process.kill()
                self.process.join(timeout=1)
        self.parent.close()
